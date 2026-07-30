# frozen_string_literal: true

require "securerandom"

require_relative "gui/request"
require_relative "gui/response"
require_relative "gui/connection"
require_relative "gui/server"
require_relative "gui/session"
require_relative "gui/presenter"
require_relative "gui/app"

module FileOrganizer
  # The graphical interface. It is a single-page app served to the browser by a
  # small loopback-only HTTP server, which keeps the program's two promises
  # intact: no gem dependencies, and no network access — 127.0.0.1 is not the
  # network, nothing is ever fetched from outside, and the page itself is
  # forbidden by its own Content-Security-Policy to load anything that is not
  # served by this program.
  module Gui
    TOKEN_BYTES = 24
    ID_PATTERN = /\A[A-Za-z0-9_-]{1,700}\z/

    module_function

    def start(directory:, mode: :general, port: 0, open_browser: true, read_only: false, dry_run: false)
      session = Session.new(directory, mode: mode, read_only: read_only, dry_run: dry_run)
      token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
      server = Server.new(port: port).start
      app = App.new(session: session, token: token, hosts: server.hosts,
                    origin: server.origin, on_quit: -> { server.stop })

      announce(session, server.url("/?t=#{token}"), open_browser)
      server.run(app)
      Console.say("GUI stopped.")
    rescue Errno::EADDRINUSE, Errno::EACCES => e
      abort("file_organizer: could not listen on port #{port}: #{e.message}")
    end

    # File names travel to the browser and back as opaque ids. A name can be
    # bytes that are not valid UTF-8, and those survive neither JSON nor a URL;
    # an id does, and it also means no request ever carries a path. The Base64
    # is done with pack/unpack so that not even a bundled gem is needed.
    def encode_id(name)
      [name.b].pack("m0").tr("+/", "-_").delete("=")
    end

    def decode_id(id)
      return nil unless id.is_a?(String) && ID_PATTERN.match?(id)

      padded = id.tr("-_", "+/")
      padded += "=" * ((4 - (padded.bytesize % 4)) % 4)
      padded.unpack1("m").force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      nil
    end

    def announce(session, url, open_browser)
      Console.say
      Console.rule("File Organizer #{VERSION} — graphical interface")
      Console.field("Folder", Console.safe(session.directory))
      Console.field("Address", url)
      Console.field("Mode", "read-only — nothing can be modified, opened, or deleted") if session.read_only?
      Console.field("Mode", "dry run — actions are reported, no file is changed") if session.dry_run?
      Console.say
      Console.say("  The address carries a one-time key for this session: it works only")
      Console.say("  from this machine, and only until the program stops.")
      Console.say("  Press Ctrl-C here, or use Quit in the page, to stop.")
      Console.say
      Console.flush
      return unless open_browser

      Console.say(Viewer.open_url(url) ? "  Opening your browser…" : "  No browser could be launched — open the address above yourself.")
      Console.say
      Console.flush
    end
  end
end
