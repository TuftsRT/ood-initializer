require "etc"

Rails.application.config.after_initialize do
  storage_roots = [
    ["/cluster/tufts", "Tier1", 1],
    ["/cluster/tier2", "Tier2", 2]
  ].freeze

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
    # too. This is only the *current* user's name, not a scan of all users, so
    # it adds at most one stat() per storage root at dashboard boot.
    username = begin
      Etc.getpwuid(Process.uid).name
    rescue StandardError
      nil
    end

    # Directory names to probe under each storage root: the user's Unix groups
    # (shared lab/project storage) plus the user's own username (personal
    # storage). The File.directory? check below means non-existent candidates
    # cost one stat and are silently skipped.
    probe_names = (group_names + [username]).compact.uniq.sort

    storage_roots.flat_map do |root, tier_label, tier_order|
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
          favorite: FavoritePath.new(candidate, title: "#{display_name} (#{tier_label})"),
          group: display_name,
          tier_order: tier_order
        }
      end
    end.sort_by do |item|
      [item[:tier_order], item[:group]]
    end.map do |item|
      item[:favorite]
    end
  rescue StandardError => e
    Rails.logger.warn("[ood.rb] shared storage discovery failed: #{e.class}: #{e.message}")
    []
  end

  OodFilesApp.candidate_favorite_paths.tap do |paths|
    favorite_paths.each { |fav| paths << fav }
  end
end
