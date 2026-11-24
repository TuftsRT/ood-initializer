require "etc"
require "json"
require "fileutils"

Rails.application.config.after_initialize do
  storage_roots = [
    ["/cluster/tufts", "Tier1", 1],
    ["/cluster/tier2", "Tier2", 2]
  ].freeze

  # /cluster/tufts and /cluster/tier2 are wildcard autofs maps, so every probe
  # below (even for a name that doesn't exist) triggers an NFS mount attempt.
  # Cold, that costs several seconds per dashboard (PUN) start, and a hung NFS
  # server would block startup. So we cache the discovered paths per user and
  # skip probing entirely while the cache is fresh.
  #
  # The cache is invalidated when:
  #   - it is older than CACHE_TTL,
  #   - the user's groups/username or the storage roots change (cache key),
  #   - CACHE_VERSION is bumped (e.g. after changing the logic in this file).
  # Users can force a refresh by deleting ~/.cache/ood/favorite_paths.json.
  cache_ttl     = 24 * 60 * 60 # seconds
  cache_version = 1

  # A probe of a *non-existent* name under /cluster/tier2 makes autofs try an
  # NFS mount that takes ~30s to fail, and the process sits in uninterruptible
  # sleep (D state) meanwhile. With ~35 groups probed one after another that is
  # many minutes, so Passenger gives up and the dashboard never starts.
  # Probes therefore run in parallel threads and boot waits at most
  # probe_deadline seconds; anything slower is left out of this session's
  # menu and filled in by a background thread that writes the cache once all
  # probes finish, so the next dashboard start gets the complete list.
  probe_deadline = (ENV["OOD_FAVORITES_PROBE_DEADLINE"] || 5).to_f

  write_cache = lambda do |cache_file, cache_key, entries|
    next unless cache_file

    tmp = "#{cache_file}.#{Process.pid}.#{Thread.current.object_id}.tmp"
    begin
      # Write atomically (temp file + rename) so a concurrent PUN start never
      # reads a half-written file. Failure here is non-fatal.
      FileUtils.mkdir_p(File.dirname(cache_file))
      File.write(tmp, JSON.pretty_generate(
        "created_at" => Time.now.to_i,
        "key"        => cache_key,
        "entries"    => entries
      ))
      File.rename(tmp, cache_file)
    rescue StandardError => e
      Rails.logger.warn("[ood.rb] could not write favorites cache #{cache_file}: #{e.class}: #{e.message}")
      File.delete(tmp) if File.exist?(tmp) rescue nil
    end
  end

  # Turn probe results ([candidate, title, group, tier_order] or nil) into
  # sorted cache entries.
  build_entries = lambda do |results|
    results.compact.sort_by { |_, _, group, order| [order, group] }
           .map { |path, title, _, _| { "path" => path, "title" => title } }
  end

  favorite_paths = begin
    group_names = Process.groups.map do |gid|
      begin
        Etc.getgrgid(gid).name
      rescue StandardError
        nil
      end
    end.compact

    # The logged-in user's own name. A few users have personal Tier1 storage
    # named after their username (e.g. /cluster/tufts/<username>), so probe that
    # too. This is only the *current* user's name, not a scan of all users.
    username = begin
      Etc.getpwuid(Process.uid).name
    rescue StandardError
      nil
    end

    # Directory names to probe under each storage root: the user's Unix groups
    # (shared lab/project storage) plus the user's own username (personal
    # storage). Non-existent candidates are silently skipped.
    probe_names = (group_names + [username]).compact.uniq.sort

    cache_file = begin
      File.join(Dir.home, ".cache", "ood", "favorite_paths.json")
    rescue StandardError
      nil # no usable $HOME: just probe every time
    end

    cache_key = {
      "version" => cache_version,
      "names"   => probe_names,
      "roots"   => storage_roots.map(&:first)
    }

    # ---- Try the cache first ------------------------------------------------
    cached_entries = begin
      if cache_file && File.file?(cache_file)
        data = JSON.parse(File.read(cache_file))
        fresh = (Time.now.to_i - data["created_at"].to_i).between?(0, cache_ttl)
        data["entries"] if fresh && data["key"] == cache_key && data["entries"].is_a?(Array)
      end
    rescue StandardError
      nil # corrupt/unreadable cache: fall through to probing
    end

    entries = cached_entries || begin
      # ---- Cache miss: probe the filesystem in parallel ---------------------
      candidates = storage_roots.flat_map do |root, tier_label, tier_order|
        probe_names.map do |name|
          # Keep the real name for the actual filesystem path, and use a
          # cleaned display name only for the Files menu title.
          #   "tts_rsch_root" -> /cluster/tufts/tts_rsch_root, "root (Tier1)"
          display_name = name.delete_prefix("tts_rsch_")
          [File.join(root, name), "#{display_name} (#{tier_label})", display_name, tier_order]
        end
      end

      # Personal scratch space: /cluster/scratch/<username>. tier_order 99
      # sorts it after the Tier1/Tier2 entries.
      candidates << [File.join("/cluster/scratch", username), "Scratch", "", 99] if username

      threads = candidates.map do |candidate|
        Thread.new do
          path = candidate.first
          File.directory?(path) && File.executable?(path) ? candidate : nil
        rescue StandardError
          nil
        end
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + probe_deadline
      timed_out = false
      results = threads.map do |t|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if t.join([remaining, 0].max)
          t.value
        else
          timed_out = true
          nil
        end
      end

      if timed_out
        Rails.logger.warn("[ood.rb] some storage probes exceeded #{probe_deadline}s; " \
                          "finishing them in the background to fill the cache")
        # Don't cache the partial list. Let the slow probes finish, then cache
        # the full result for the next dashboard start.
        Thread.new do
          write_cache.call(cache_file, cache_key, build_entries.call(threads.map(&:value)))
        rescue StandardError => e
          Rails.logger.warn("[ood.rb] background favorites probe failed: #{e.class}: #{e.message}")
        end
      else
        write_cache.call(cache_file, cache_key, build_entries.call(results))
      end

      build_entries.call(results)
    end

    entries.map { |e| FavoritePath.new(e["path"], title: e["title"]) }
  rescue StandardError => e
    Rails.logger.warn("[ood.rb] shared storage discovery failed: #{e.class}: #{e.message}")
    []
  end

  OodFilesApp.candidate_favorite_paths.tap do |paths|
    favorite_paths.each { |fav| paths << fav }
  end
end
