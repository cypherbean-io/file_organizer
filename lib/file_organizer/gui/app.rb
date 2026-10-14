# frozen_string_literal: true

require "digest"

module FileOrganizer
  module Gui
    # Routing and request handling for the GUI.
    #
    # Three rules guard every request before it can touch a file:
    #
    # * the Host header must name our own loopback address, so a hostile page
    #   cannot reach the server by resolving a name to 127.0.0.1;
    # * every page and API request must carry the one-time session key, which
    #   only the terminal that launched the program has printed;
    # * files are addressed by opaque ids that decode to a single path
    #   component inside the directory being reviewed — never by path.
    class App
      WEB_ROOT = File.join(__dir__, "web")

      # The interface's own files. They hold no information about the user's
      # files, so they are the only thing served without the session key —
      # the browser asks for them before any script of ours can run.
      ASSETS = {
        "/" => ["index.html", "text/html; charset=utf-8"],
        "/assets/app.css" => ["app.css", "text/css; charset=utf-8"],
        "/assets/app.js" => ["app.js", "text/javascript; charset=utf-8"],
        "/assets/favicon.svg" => ["favicon.svg", "image/svg+xml"]
      }.freeze

      # The page loads no code, styles, fonts or images from anywhere but this
      # server, and cannot be framed or submit a form anywhere.
      CSP = "default-src 'none'; script-src 'self'; style-src 'self'; " \
            "img-src 'self' data:; media-src 'self'; connect-src 'self'; " \
            "form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

      MAX_RANGE_BYTES = 16 * 1024 * 1024

      # Routes that change a file or hand it to another program. Read-only mode
      # refuses every one of them on the server, whatever the page shows.
      MUTATING_ROUTES = %w[/api/rename /api/copy /api/move /api/delete /api/open].freeze

      UNAUTHORIZED = "Not authorized. Open the address that file_organizer printed in your terminal " \
                     "— it carries the one-time key for this session."

      def initialize(session:, token:, hosts:, origin:, on_quit: nil)
        @session = session
        @token = token
        @hosts = hosts
        @origin = origin
        @on_quit = on_quit
      end

      def call(request)
        return Response.text("Unexpected Host header.", status: 403) unless allowed_host?(request)

        request.get? ? handle_get(request) : handle_post(request)
      rescue StandardError => e
        warn("file_organizer: GUI error: #{e.class}: #{e.message}")
        Response.json({ "status" => "error", "message" => "The program hit an internal error." }, status: 500)
      end

      private

      # --- routing ------------------------------------------------------------

      def handle_get(request)
        path = request.path
        return asset(path) if ASSETS.key?(path) && path != "/"
        return Response.text(UNAUTHORIZED, status: 403) unless authorized?(request)

        case path
        when "/" then asset("/")
        when "/api/session" then session_payload
        when "/api/files" then files_payload
        when "/api/file" then file_payload(request)
        when "/api/text" then text_payload(request)
        when "/api/raw" then raw_payload(request)
        when "/api/hash" then hash_payload(request)
        else Response.text("Not found.", status: 404)
        end
      end

      def handle_post(request)
        return Response.text(UNAUTHORIZED, status: 403) unless authorized?(request)
        return Response.text("Cross-origin request refused.", status: 403) unless same_origin?(request)
        return read_only_refusal if @session.read_only? && MUTATING_ROUTES.include?(request.path)

        case request.path
        when "/api/rename" then rename(request)
        when "/api/copy" then transfer(request, :copy)
        when "/api/move" then transfer(request, :move)
        when "/api/delete" then delete(request)
        when "/api/open" then open_file(request)
        when "/api/folder" then change_folder(request)
        when "/api/quit" then quit
        else Response.text("Not found.", status: 404)
        end
      end

      # --- guards -------------------------------------------------------------

      def allowed_host?(request)
        host = request.header("host")
        host.nil? || @hosts.include?(host.downcase)
      end

      def authorized?(request)
        provided = request.header("x-session-token") || request.param("t")
        provided.is_a?(String) && secure_equal?(provided, @token)
      end

      # Compares digests so the check does not leak the key's prefix through
      # its own running time.
      def secure_equal?(given, expected)
        Digest::SHA256.digest(given) == Digest::SHA256.digest(expected) &&
          given.bytesize == expected.bytesize
      end

      # Browsers label same-origin writes; anything labelled otherwise is not
      # coming from our page and is refused even if it somehow has the key.
      def same_origin?(request)
        origin = request.header("origin")
        site = request.header("sec-fetch-site")
        (origin.nil? || origin == @origin) && (site.nil? || site == "same-origin")
      end

      # --- reads --------------------------------------------------------------

      def asset(path)
        name, content_type = ASSETS.fetch(path)
        body = File.binread(File.join(WEB_ROOT, name))
        extra = path == "/" ? { "Content-Security-Policy" => CSP } : {}
        Response.asset(body, content_type: content_type, extra_headers: extra)
      rescue SystemCallError
        Response.text("Missing interface file: #{name}", status: 500)
      end

      def session_payload
        subdirectories, more = @session.subdirectories
        Response.json({
                        "directory" => Console.safe(@session.directory),
                        "parent" => @session.parent && Console.safe(@session.parent),
                        "subdirectories" => subdirectories.map { |name| directory_entry(name) },
                        "moreSubdirectories" => more,
                        "mode" => @session.mode.to_s,
                        "readOnly" => @session.read_only?,
                        "dryRun" => @session.dry_run?,
                        "version" => VERSION,
                        "separator" => File::SEPARATOR
                      })
      end

      def directory_entry(name)
        { "name" => Console.safe(name), "path" => Console.safe(File.join(@session.directory, name)) }
      end

      def files_payload
        listing = @session.listing
        generation = listing[:generation]
        Response.json({
                        "directory" => Console.safe(listing[:directory]),
                        "generation" => generation,
                        "truncated" => listing[:truncated],
                        "limit" => Session::MAX_ENTRIES,
                        "files" => listing[:entries].map do |info|
                          Presenter.summary(info, id: @session.id_for(info.name, generation))
                        end
                      })
      end

      def file_payload(request)
        with_file(request) do |info, generation|
          Response.json(Presenter.detail(info, id: @session.id_for(info.name, generation)))
        end
      end

      def text_payload(request)
        with_file(request) do |info|
          next failure("A preview in the page is only available for text-based files.") unless info.textual?

          lines, truncated = Viewer.text_preview(info.path)
          Response.json({ "status" => "ok", "lines" => lines, "truncated" => truncated })
        end
      end

      def raw_payload(request)
        with_file(request) do |info|
          type = info.regular? ? Presenter.content_type(info.content_format) : nil
          next Response.text("This file is not served to the page.", status: 415) if type.nil?

          total = info.size
          offset, length, satisfiable = byte_range(request.header("range"), total)
          next unsatisfiable_range(total) unless satisfiable

          Response.file(info.path, content_type: type, offset: offset, length: length, total: total)
        end
      end

      def hash_payload(request)
        with_file(request) do |info|
          next failure("Checksums are only available for regular files.") unless info.regular?

          status, digest = @session.checksum(info)
          case status
          when :ok then Response.json({ "status" => "ok", "sha256" => digest })
          when :busy then failure("The checksum of this file is already being computed — it will appear when ready.")
          else failure("Stopped before the checksum was finished.")
          end
        rescue SystemCallError, IOError => e
          failure("Could not compute checksum: #{e.message}")
        end
      end

      # --- writes -------------------------------------------------------------

      def rename(request)
        with_file(request) do |info, generation|
          new_name = request.string("name").to_s
          next failure("A new name is required.") if new_name.empty?

          report(Operations.rename(info.path, new_name, dry_run: @session.dry_run?), generation)
        end
      end

      # Replacing a file that is already there cannot be undone, so — as in
      # the terminal — it takes the word "yes", checked here and not only in
      # the page.
      def transfer(request, operation)
        with_file(request) do |info, generation|
          destination = request.string("destination").to_s
          next failure("A destination folder is required.") if destination.empty?

          overwrite = request.json["overwrite"] == true
          if overwrite && request.string("confirm") != "yes"
            next failure("Overwriting needs the word 'yes' as confirmation.")
          end

          report(Operations.transfer(info.path, destination, operation,
                                     overwrite: overwrite, dry_run: @session.dry_run?), generation)
        end
      end

      # The typed confirmation is enforced here, not only in the page: nothing
      # is deleted unless the request says so in as many words.
      def delete(request)
        with_file(request) do |info, generation|
          next failure("Deleting needs the word 'yes' as confirmation.") unless request.string("confirm") == "yes"

          report(Operations.delete(info.path, dry_run: @session.dry_run?), generation)
        end
      end

      # The system picks the application from the extension, so a file whose
      # extension disagrees with its content — a common disguise — is only
      # opened once the request confirms it in as many words.
      def open_file(request)
        with_file(request) do |info|
          unless info.openable?
            next failure("Opening is disabled for this file (executable content, a launcher file type, " \
                         "or not a regular file).")
          end
          if info.extension_mismatch? && request.string("confirm") != "yes"
            next needs_confirmation("This file's extension disagrees with its actual content — a common " \
                                    "disguise. The system will pick the application from the extension, " \
                                    "not from the content.")
          end
          next success("[dry run] would hand the file to the system default application.") if @session.dry_run?
          next success("Opened with the system default application.") if Viewer.open_with_default_app(info.path)

          failure("Could not open the file (no system opener available).")
        end
      end

      # System and home directories are almost never what someone means to
      # reorganize, so — as in the terminal — moving into one takes an
      # explicit "yes", unless nothing can be changed anyway.
      def change_folder(request)
        path = request.string("path").to_s
        return failure("A folder is required.") if path.empty?

        if guarded_folder?(path) && request.string("confirm") != "yes"
          return needs_confirmation("#{path} is a system or home directory — its files are almost " \
                                    "certainly not what you meant to reorganize.")
        end

        error = @session.change_directory(path)
        return failure(capitalize(error)) if error

        success("Now reviewing #{@session.directory}.")
      end

      def guarded_folder?(path)
        !@session.read_only? && Directory.guarded?(File.expand_path(path))
      rescue ArgumentError
        false
      end

      def quit
        # Answer first, stop a moment later, so the page can say goodbye.
        @session.stop!
        Thread.new do
          sleep(0.25)
          @on_quit&.call
        end
        success("Stopping. You can close this tab.")
      end

      # --- helpers ------------------------------------------------------------

      # Resolves the requested file once and hands it, with the folder
      # generation its id was issued in, to the block, so no handler ever sees
      # a client-supplied path.
      def with_file(request)
        lookup = @session.lookup(request.param("id") || request.string("id"))
        return stale_file if lookup.error == :stale
        return missing_file if lookup.info.nil?

        yield lookup.info, lookup.generation
      end

      def missing_file
        Response.json({ "status" => "error", "message" => "That file is no longer there." }, status: 404)
      end

      # The page is showing a folder the program has since left (another tab
      # changed it). Acting on the id now would hit a different file.
      def stale_file
        Response.json({ "status" => "error", "stale" => true,
                        "message" => "The folder changed since this page loaded it — showing it again now." },
                      status: 409)
      end

      def report(result, generation)
        Response.json({
                        "status" => result.status.to_s,
                        "message" => Console.safe(result.message),
                        "id" => result.path && @session.id_for(File.basename(result.path), generation)
                      })
      end

      def success(message)
        Response.json({ "status" => "ok", "message" => Console.safe(message) })
      end

      def failure(message)
        Response.json({ "status" => "error", "message" => Console.safe(message) })
      end

      # Nothing was done; repeat the request with "confirm": "yes" to go ahead.
      def needs_confirmation(message)
        Response.json({ "status" => "confirm", "message" => Console.safe(message) })
      end

      def read_only_refusal
        Response.json({ "status" => "error",
                        "message" => "Read-only mode: nothing can be modified, opened, or deleted." }, status: 403)
      end

      def capitalize(text)
        text.to_s.sub(/\A./, &:upcase)
      end

      def unsatisfiable_range(total)
        Response.new(status: 416,
                     headers: { "Content-Type" => "text/plain; charset=utf-8",
                                "Content-Range" => "bytes */#{total}" })
      end

      # Single "bytes=first-last" ranges only — all a browser needs to seek in
      # an audio or video element. Returns [offset, length, satisfiable?].
      def byte_range(header, total)
        match = header && /\Abytes=(\d{0,15})-(\d{0,15})\z/.match(header.strip)
        return [0, total, true] if match.nil? || total.zero?

        first, last = match.captures
        offset, finish = first.empty? ? suffix_range(last, total) : prefix_range(first, last, total)
        return [0, total, false] if offset.nil? || finish < offset || offset >= total

        [offset, [finish - offset + 1, MAX_RANGE_BYTES].min, true]
      end

      def suffix_range(last, total)
        length = last.to_i
        return [nil, 0] if last.empty? || length.zero?

        [[total - length, 0].max, total - 1]
      end

      def prefix_range(first, last, total)
        offset = first.to_i
        finish = last.empty? ? total - 1 : [last.to_i, total - 1].min
        [offset, finish]
      end
    end
  end
end
