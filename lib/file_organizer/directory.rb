# frozen_string_literal: true

module FileOrganizer
  # Reading a directory: validating it, listing the files inside it, and
  # recognising the ones nobody should be reorganizing by accident.
  #
  # Only regular files and symlinks are ever listed — subdirectories are
  # never touched.
  module Directory
    # Directories whose contents are almost never what someone means to
    # reorganize; pointing at one takes an explicit confirmation first.
    GUARDED = %w[
      /bin /boot /dev /etc /lib /lib32 /lib64 /proc /root /sbin /srv /sys
      /usr /var /Applications /Library /System /Volumes /Windows
    ].freeze

    module_function

    # Returns a lowercase description of why the directory cannot be used, or
    # nil when it is usable. Callers sanitize the message for their medium.
    def error(path, access: :read)
      return "does not exist: #{path}" unless File.exist?(path)
      return "not a directory: #{path}" unless File.directory?(path)

      if access == :write
        return "directory is not writable: #{path}" unless File.writable?(path)
      elsif !File.readable?(path)
        return "directory is not readable: #{path}"
      end

      nil
    end

    # Returns [entries, truncated?] where entries are FileInfo objects for the
    # regular files and symlinks in +directory+, sorted by name. With +limit+
    # only that many directory entries are read at all, so a directory with an
    # absurd number of them costs no more than one with +limit+; which ones
    # are shown is then up to the order the filesystem returns them in.
    #
    # One lstat per entry: no file's content is read until something asks for
    # it.
    def entries(directory, limit: nil)
      names, truncated = children(directory, limit: limit)
      infos = names.filter_map do |name|
        info = FileInfo.new(File.join(directory, name))
        info if info.regular? || info.symlink?
      rescue SystemCallError
        nil
      end
      [infos, truncated]
    end

    # Returns [names, truncated?]: the real subdirectories (not links to
    # one), sorted. At most +scan+ entries are examined and +limit+ names
    # returned, so a folder of millions of files stays cheap to describe.
    def subdirectories(directory, limit: 500, scan: 20_000)
      names, scan_truncated = children(directory, limit: scan)
      found = names.select do |name|
        File.lstat(File.join(directory, name)).directory?
      rescue SystemCallError
        false
      end
      [found.first(limit), scan_truncated || found.size > limit]
    end

    # Returns [names, truncated?], sorted with a byte-wise key: a file name
    # that is not valid UTF-8 (which the filesystem happily allows) would make
    # String#downcase raise. With +limit+, reading stops after that many.
    def children(directory, limit: nil)
      names = []
      truncated = false
      Dir.each_child(directory) do |name|
        if limit && names.size >= limit
          truncated = true
          break
        end
        names << name
      end
      [names.sort_by { |name| [name.b.downcase, name.b] }, truncated]
    rescue SystemCallError
      [[], false]
    end

    # Compared both as written — with repeated separators collapsed, since
    # "//etc" is /etc — and as it resolves, so a symlink to /etc is /etc too.
    def guarded?(directory)
      [directory, resolve(directory)].compact.uniq.any? do |path|
        guarded_path?(path.squeeze(File::SEPARATOR))
      end
    end

    def guarded_path?(path)
      return true if path == File::SEPARATOR
      return true if [home, resolve(home)].compact.include?(path)

      GUARDED.any? { |root| path == root || path.start_with?("#{root}/") }
    end

    def resolve(path)
      path && File.realpath(path)
    rescue SystemCallError, ArgumentError
      nil
    end

    def home
      File.expand_path(Dir.home)
    rescue ArgumentError
      nil
    end
  end
end
