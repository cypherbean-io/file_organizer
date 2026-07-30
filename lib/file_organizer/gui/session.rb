# frozen_string_literal: true

module FileOrganizer
  module Gui
    # The state the GUI keeps between requests: which directory is being
    # reviewed, how (read-only, dry run), and what it already knows about the
    # content of the files in it. Worker threads share a single Session, so
    # every read and write of that state goes through the mutex.
    class Session
      # Only this many directory entries are listed, so a directory with an
      # absurd number of them cannot exhaust memory or the page.
      MAX_ENTRIES = 5_000

      # Upper bound on remembered type detections before the memory is reset.
      MAX_DETECTIONS = 20_000

      attr_reader :mode

      def initialize(directory, mode: :general, read_only: false, dry_run: false)
        @lock = Mutex.new
        @directory = directory
        @mode = mode
        @read_only = read_only
        @dry_run = dry_run && !read_only
        @detections = {}
      end

      # Read-only refuses every action that changes a file or hands it to
      # another program; it wins over dry run.
      def read_only?
        @read_only
      end

      def dry_run?
        @dry_run
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

        @lock.synchronize do
          @directory = expanded
          @detections.clear
        end
        nil
      rescue ArgumentError => e # File.expand_path on "~nosuchuser"
        e.message
      end

      # The folder as it is right now: { directory:, entries: [FileInfo],
      # truncated: }. Nothing is cached, so the page never shows a listing that
      # the filesystem has moved on from.
      #
      # Every listing re-reads the directory, but a file's content is only
      # examined again when the file itself has changed.
      def listing
        directory = self.directory
        entries, truncated = Directory.entries(directory, limit: MAX_ENTRIES)
        entries.each { |info| reuse_detection(info) }
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

        info = FileInfo.new(File.join(directory, name))
        return nil unless info.regular? || info.symlink?

        reuse_detection(info)
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

      private

      # Type detection reads the head of the file. It is remembered against
      # FileInfo#content_key — which changes whenever the file is replaced,
      # resized or written to — so refreshing a large folder does not re-read
      # every file in it. Returns +info+.
      def reuse_detection(info)
        return info unless info.regular?

        key = info.content_key
        cached = @lock.synchronize { @detections[key] }
        if cached
          info.detection = cached
        else
          detection = info.detection
          @lock.synchronize do
            @detections.clear if @detections.size >= MAX_DETECTIONS
            @detections[key] = detection
          end
        end
        info
      end
    end
  end
end
