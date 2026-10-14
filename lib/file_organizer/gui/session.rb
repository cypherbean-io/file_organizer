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

      # Upper bounds on remembered detections and checksums before the memory
      # is reset.
      MAX_DETECTIONS = 20_000
      MAX_CHECKSUMS = 2_000

      # The answer to "which file does this id mean?". +error+ is :stale when
      # the id was handed out for a folder the session has since left, and
      # :missing when it names nothing usable here.
      Lookup = Struct.new(:info, :generation, :error, keyword_init: true)

      ID_FORMAT = /\A([0-9a-z]{1,12})\.([A-Za-z0-9_-]{1,700})\z/

      attr_reader :mode

      def initialize(directory, mode: :general, read_only: false, dry_run: false)
        @lock = Mutex.new
        @directory = directory
        @generation = 1
        @mode = mode
        @read_only = read_only
        @dry_run = dry_run && !read_only
        @stopped = false
        @detections = {}
        @checksums = {}
        @hashing = {}
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

      # Counts folder changes. Every file id carries the generation it was
      # handed out in, so a page still showing an earlier folder — another
      # tab, or a request already in flight — cannot act on a file of the
      # same name in the folder that replaced it.
      def generation
        @lock.synchronize { @generation }
      end

      # Returns nil on success, or a lowercase reason why the directory cannot
      # be used.
      def change_directory(path)
        expanded = File.expand_path(path)
        error = Directory.error(expanded)
        return error if error

        @lock.synchronize do
          @directory = expanded
          @generation += 1
          @detections.clear
        end
        nil
      rescue ArgumentError => e # File.expand_path on "~nosuchuser"
        e.message
      end

      # The folder as it is right now: { directory:, generation:,
      # entries: [FileInfo], truncated: }. The directory is re-read every time,
      # so the page never shows a listing that the filesystem has moved on
      # from, but a file's content is only examined again when the file
      # itself has changed.
      def listing
        directory, generation = @lock.synchronize { [@directory, @generation] }
        entries, truncated = Directory.entries(directory, limit: MAX_ENTRIES)
        entries.each { |info| reuse_detection(info) }
        { directory: directory, generation: generation, entries: entries, truncated: truncated }
      end

      # The opaque id the page uses for the file +name+ in the folder of
      # +generation+: the generation, then the name in URL-safe Base64.
      def id_for(name, generation = self.generation)
        "#{generation.to_s(36)}.#{Gui.encode_id(name)}"
      end

      # Resolves an opaque id from the browser to a fresh FileInfo.
      #
      # This is the only route from a request to the filesystem, and the reason
      # a crafted id cannot reach outside the directory being reviewed: the
      # decoded name has to be a single path component, and it is joined onto
      # the current directory rather than used as a path of its own — and only
      # if the id was handed out for that directory.
      def lookup(id)
        match = id.is_a?(String) && ID_FORMAT.match(id)
        return Lookup.new(error: :missing) unless match

        name = Gui.decode_id(match[2])
        return Lookup.new(error: :missing) if name.nil? || !Operations.single_component?(name)

        directory, current = @lock.synchronize { [@directory, @generation] }
        return Lookup.new(error: :stale) unless match[1].to_i(36) == current

        info = FileInfo.new(File.join(directory, name))
        return Lookup.new(error: :missing) unless info.regular? || info.symlink?

        Lookup.new(info: reuse_detection(info), generation: current)
      rescue SystemCallError
        Lookup.new(error: :missing)
      end

      # The FileInfo an id resolves to, or nil.
      def find(id)
        lookup(id).info
      end

      # Returns [names, truncated?] for the real subdirectories.
      def subdirectories
        Directory.subdirectories(directory)
      end

      def parent
        current = directory
        parent = File.dirname(current)
        parent == current ? nil : parent
      end

      # SHA-256 of a regular file, as [:ok, hex]. A checksum is remembered
      # against the file's content_key, and only one is ever computed per
      # file at a time: asking again while it runs gives [:busy, nil] rather
      # than a second full read of what may be a very large file. Gives
      # [:stopped, nil] when the program stopped meanwhile. Raises
      # SystemCallError or IOError when the file cannot be read.
      def checksum(info)
        key = info.content_key
        @lock.synchronize do
          return [:ok, @checksums[key]] if @checksums.key?(key)
          return [:busy, nil] if @hashing.key?(key)

          @hashing[key] = true
        end

        begin
          digest = SafeFile.sha256(info.path, stop: -> { stopped? })
        ensure
          @lock.synchronize { @hashing.delete(key) }
        end
        return [:stopped, nil] if digest.nil?

        @lock.synchronize do
          @checksums.clear if @checksums.size >= MAX_CHECKSUMS
          @checksums[key] = digest
        end
        [:ok, digest]
      end

      # Tells long-running work (a checksum of a huge file) to give up: the
      # program is stopping.
      def stop!
        @lock.synchronize { @stopped = true }
      end

      def stopped?
        @lock.synchronize { @stopped }
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
