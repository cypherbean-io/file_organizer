# frozen_string_literal: true

module FileOrganizer
  # Reading a directory: validating it, and listing the files inside it.
  #
  # Only regular files and symlinks are ever listed — subdirectories are
  # never touched — and the listing is capped so a directory with an absurd
  # number of entries cannot exhaust memory.
  module Directory
    MAX_ENTRIES = 5_000

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
    # regular files and symlinks in +directory+, sorted by name.
    def entries(directory)
      names = children(directory)
      truncated = names.size > MAX_ENTRIES
      infos = names.first(MAX_ENTRIES).filter_map do |name|
        path = File.join(directory, name)
        next unless File.symlink?(path) || File.file?(path)

        FileInfo.new(path)
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
  end
end
