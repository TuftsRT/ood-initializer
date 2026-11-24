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
      # ---- Cache miss: probe the filesystem ---------------------------------
      tier_entries = storage_roots.flat_map do |root, tier_label, tier_order|
        probe_names.filter_map do |name|
          # Keep the real name for the actual filesystem path.
          # Example:
          #   name      = "tts_rsch_root"  -> "/cluster/tufts/tts_rsch_root"
          #   name      = "yzhang85"       -> "/cluster/tufts/yzhang85"
          candidate = File.join(root, name)

          next unless File.directory?(candidate) && File.executable?(candidate)

          # Use a cleaned display name only for the Files menu title.
          # Example:
          #   "tts_rsch_root" -> "root"
          #   "aldridgelab"   -> "aldridgelab"
          display_name = name.delete_prefix("tts_rsch_")

          {
            "path"       => candidate,
            "title"      => "#{display_name} (#{tier_label})",
            "group"      => display_name,
            "tier_order" => tier_order
          }
        end
      end.sort_by do |item|
        [item["tier_order"], item["group"]]
      end.map do |item|
        item.slice("path", "title")
      end

      # Personal scratch space: /cluster/scratch/<username>. Listed after the
      # Tier1/Tier2 entries and skipped if it doesn't exist or isn't accessible.
      scratch_entries = []
      if username
        scratch = File.join("/cluster/scratch", username)
        if File.directory?(scratch) && File.executable?(scratch)
          scratch_entries << { "path" => scratch, "title" => "Scratch" }
        end
      end

      probed = tier_entries + scratch_entries

      # Write the cache atomically (temp file + rename) so a concurrent PUN
      # start never reads a half-written file. Failure here is non-fatal.
      if cache_file
        begin
          FileUtils.mkdir_p(File.dirname(cache_file))
          tmp = "#{cache_file}.#{Process.pid}.tmp"
          File.write(tmp, JSON.pretty_generate(
            "created_at" => Time.now.to_i,
            "key"        => cache_key,
            "entries"    => probed
          ))
          File.rename(tmp, cache_file)
        rescue StandardError => e
          Rails.logger.warn("[ood.rb] could not write favorites cache #{cache_file}: #{e.class}: #{e.message}")
          File.delete(tmp) if tmp && File.exist?(tmp) rescue nil
        end
      end

      probed
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
