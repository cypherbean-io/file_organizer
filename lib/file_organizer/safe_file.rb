# frozen_string_literal: true

module FileOrganizer
  # Opens files for reading without ever following a symbolic link.
  #
  # Every path the program reads has been classified with lstat first.
  # Re-opening it with O_NOFOLLOW makes sure the bytes that get read still
  # come from the regular file that was classified, and not from something
  # swapped in behind it. O_NONBLOCK keeps a named pipe from parking the
  # process forever in open(2) if one appears at that path.
  module SafeFile
    NOFOLLOW = defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0
    FLAGS = File::RDONLY | NOFOLLOW |
            (defined?(File::NONBLOCK) ? File::NONBLOCK : 0) |
            (defined?(File::BINARY) ? File::BINARY : 0)

    module_function

    def open(path)
      io = File.open(path, FLAGS)
      io.binmode
      return io unless block_given?

      begin
        yield io
      ensure
        io.close
      end
    end

    # Reads at most +length+ bytes; returns nil at end of file.
    def read(path, length)
      open(path) { |io| io.read(length) }
    end
  end
end
