# frozen_string_literal: true

require "socket"

module FileOrganizer
  # The graphical interface: a single-page app served to the browser by a
  # loopback-only HTTP server built on the standard library.
  module Gui
    # A deliberately small HTTP/1.1 server. It binds to the loopback interface
    # only, so it is never reachable from the network, and it speaks just enough
    # HTTP for one local browser: GET, POST, keep-alive and byte ranges.
    #
    # One thread waits on every open socket at once and hands a connection to a
    # worker only when a request is actually arriving on it. A browser keeps
    # several connections open and idle, and a worker per connection would let a
    # handful of idle sockets starve the pool.
    class Server
      HOST = "127.0.0.1"
      WORKERS = 6
      MAX_PARKED = 256      # sockets waiting for their next request
      MAX_REQUESTS_PER_CONNECTION = 1_000
      KEEP_ALIVE_SECONDS = 65
      POLL_SECONDS = 1.0    # how often idle sockets are reaped

      STATUS_TEXT = {
        200 => "OK", 206 => "Partial Content",
        400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 409 => "Conflict", 413 => "Payload Too Large",
        415 => "Unsupported Media Type", 416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large", 500 => "Internal Server Error",
        503 => "Service Unavailable", 505 => "HTTP Version Not Supported"
      }.freeze

      # Applied to every response, whatever it carries.
      BASE_HEADERS = {
        "X-Content-Type-Options" => "nosniff",
        "X-Frame-Options" => "DENY",
        "Referrer-Policy" => "no-referrer",
        "Cross-Origin-Opener-Policy" => "same-origin",
        "Cross-Origin-Resource-Policy" => "same-origin"
      }.freeze

      attr_reader :port

      def initialize(port: 0)
        @requested_port = port
        @lock = Mutex.new
        @parked = {}
        @ready = Queue.new
        @running = false
      end

      # Binds the listening socket, so the port is known before anything is
      # served — and before the browser is pointed at it.
      def start
        @listener = TCPServer.new(HOST, @requested_port)
        @port = @listener.addr[1]
        @wake_reader, @wake_writer = IO.pipe
        self
      end

      def origin
        "http://#{HOST}:#{port}"
      end

      # Host header values we accept; anything else is a DNS rebinding attempt.
      def hosts
        ["#{HOST}:#{port}", "localhost:#{port}"]
      end

      def url(path = "/")
        "#{origin}#{path}"
      end

      def run(app)
        raise Error, "server has not been started" if @listener.nil?

        @running = true
        workers = Array.new(WORKERS) { Thread.new { worker_loop(app) } }
        event_loop
      ensure
        @running = false
        WORKERS.times { @ready.push(:stop) }
        workers&.each { |worker| worker.join(2) }
        shut_down
      end

      # Safe to call from a worker thread (the page's Quit button) or a signal
      # handler: it closes the listener, which ends the event loop.
      def stop
        @running = false
        close(@listener)
        wake
      end

      private

      # Waits on the listener, the wake-up pipe and every parked socket at once.
      def event_loop
        while @running
          readable = wait_for_activity
          (readable || []).each do |io|
            if io.equal?(@listener) then accept_connection
            elsif io.equal?(@wake_reader) then drain_wake
            else resume(io)
            end
          end
          expire_idle
        end
      end

      def wait_for_activity
        IO.select([@listener, @wake_reader, *parked_sockets], nil, nil, POLL_SECONDS)&.first
      rescue IOError, SystemCallError
        @running = false
        nil
      end

      def accept_connection
        socket = @listener.accept_nonblock(exception: false)
        return if socket.nil? || socket == :wait_readable

        if @lock.synchronize { @parked.size } >= MAX_PARKED
          close(socket)
        else
          park(Connection.new(socket))
        end
      rescue IOError, SystemCallError
        nil
      end

      # A parked socket with data waiting becomes a job for a worker.
      def resume(socket)
        connection = @lock.synchronize { @parked.delete(socket) }
        @ready.push(connection) if connection
      end

      def park(connection)
        connection.touch
        @lock.synchronize { @parked[connection.socket] = connection }
        wake
      end

      def parked_sockets
        @lock.synchronize { @parked.keys }
      end

      def expire_idle
        stale = @lock.synchronize do
          @parked.values.select { |connection| connection.idle_for > KEEP_ALIVE_SECONDS }
                 .each { |connection| @parked.delete(connection.socket) }
        end
        stale.each { |connection| close(connection.socket) }
      end

      # Lets the event loop rebuild its socket set the moment a worker parks a
      # connection, instead of waiting for the next poll.
      def wake
        @wake_writer&.write_nonblock(".")
      rescue IO::WaitWritable, IOError, SystemCallError
        nil
      end

      def drain_wake
        @wake_reader.read_nonblock(256)
      rescue IO::WaitReadable, IOError, SystemCallError
        nil
      end

      def shut_down
        close(@listener)
        close(@wake_reader)
        close(@wake_writer)
        parked = @lock.synchronize { @parked.values.tap { @parked.clear } }
        parked.each { |connection| close(connection.socket) }
      end

      # --- workers ------------------------------------------------------------

      def worker_loop(app)
        while (job = @ready.pop)
          break if job == :stop

          serve(app, job)
        end
      end

      def serve(app, connection)
        request = connection.read_request
        return close(connection.socket) if request.nil?

        response = app.call(request)
        unless write(connection.socket, response) && keep_alive?(connection, request)
          return close(connection.socket)
        end

        # Anything already buffered is the next pipelined request; the event
        # loop would never see new data arrive for it.
        connection.buffered? ? @ready.push(connection) : park(connection)
      rescue RequestError => e
        write(connection.socket, Response.text(e.message, status: e.status))
        close(connection.socket)
      rescue StandardError => e
        warn("file_organizer: GUI request failed: #{e.class}: #{e.message}")
        close(connection.socket)
      end

      def keep_alive?(connection, request)
        @running && request.keep_alive? && connection.requests < MAX_REQUESTS_PER_CONNECTION
      end

      # Returns false when the client hung up, so the connection is dropped.
      def write(socket, response)
        socket.write(head(response))
        if response.stream?
          IO.copy_stream(response.file_path, socket, response.file_length, response.file_offset)
        elsif !response.body.empty?
          socket.write(response.body)
        end
        true
      rescue IOError, SystemCallError
        false
      end

      def head(response)
        headers = BASE_HEADERS.merge(response.headers)
        headers["Content-Length"] = response.content_length.to_s
        headers["Connection"] = "keep-alive"
        lines = ["HTTP/1.1 #{response.status} #{STATUS_TEXT.fetch(response.status, "OK")}"]
        # No response header carries anything taken from a file, but a stray CR
        # or LF would still be a response-splitting bug, so they are stripped
        # rather than trusted.
        headers.each { |name, value| lines << "#{name}: #{value.to_s.delete("\r\n")}" }
        "#{lines.join("\r\n")}\r\n\r\n"
      end

      def close(io)
        io&.close unless io.nil? || io.closed?
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
