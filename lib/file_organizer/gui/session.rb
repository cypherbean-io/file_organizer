# frozen_string_literal: true

module FileOrganizer
  module Gui
    # The one piece of state the GUI keeps between requests: which directory is
    # being reviewed. Worker threads share a single Session, so every read and
    # write of it goes through the mutex.
    class Session
      attr_reader :mode

      def initialize(directory, mode: :general)
        @lock = Mutex.new
        @directory = directory
        @mode = mode
      end

      def directory
        @lock.synchronize { @directory }
      end

      # Returns nil on success, or a lowercase reason why the directory cannot
      # be used.
      def change_directory(path)
        expanded = File.expand_path(path)
        error = Directory.error(expanded)
        return error if error

        @lock.synchronize { @directory = expanded }
        nil
      end

      # The folder as it is right now: { directory:, entries: [FileInfo],
      # truncated: }. Nothing is cached, so the page never shows a listing that
      # the filesystem has moved on from.
      def listing
        directory = self.directory
        entries, truncated = Directory.entries(directory)
        { directory: directory, entries: entries, truncated: truncated }
      end

      # Resolves an opaque id from the browser to a fresh FileInfo, or nil when
      # it does not name a file directly inside the current directory.
      #
      # This is the only route from a request to the filesystem, and the reason
      # a crafted id cannot reach outside the directory being reviewed: the
      # decoded name has to be a single path component, and it is joined onto
      # the current directory rather than used as a path of its own.
      def find(id)
        name = Gui.decode_id(id)
        return nil if name.nil? || !Operations.single_component?(name)

        path = File.join(directory, name)
        return nil unless File.symlink?(path) || File.file?(path)

        FileInfo.new(path)
      rescue SystemCallError
        nil
      end

      def subdirectories
        Directory.subdirectories(directory)
      end

      def parent
        current = directory
        parent = File.dirname(current)
        parent == current ? nil : parent
      end
    end
  end
end
