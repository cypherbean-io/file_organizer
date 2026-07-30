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
    # only that many directory entries are looked at, so a directory with an
    # absurd number of them cannot exhaust memory.
    #
    # One lstat per entry: no file's content is read until something asks for
    # it.
    def entries(directory, limit: nil)
      names = children(directory)
      truncated = !limit.nil? && names.size > limit
      names = names.first(limit) if truncated
      infos = names.filter_map do |name|
        info = FileInfo.new(File.join(directory, name))
        info if info.regular? || info.symlink?
      rescue SystemCallError
        nil
      end
      [infos, truncated]
    end

    def subdirectories(directory)
      children(directory).filter_map do |name|
        path = File.join(directory, name)
        name if File.directory?(path) && !File.symlink?(path)
      rescue SystemCallError
        nil
      end
    end

    # Sorted with a byte-wise key: a file name that is not valid UTF-8 (which
    # the filesystem happily allows) would make String#downcase raise.
    def children(directory)
      Dir.children(directory).sort_by { |name| [name.b.downcase, name.b] }
    rescue SystemCallError
      []
    end

    def guarded?(directory)
      return true if directory == "/" || directory == home

      GUARDED.any? { |root| directory == root || directory.start_with?("#{root}/") }
    end

    def home
      File.expand_path(Dir.home)
    rescue ArgumentError
      nil
    end
  end
end
