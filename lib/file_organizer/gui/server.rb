# frozen_string_literal: true

require "socket"
require "io/wait"

module FileOrganizer
  # The graphical interface: a single-page app served to the browser by a
  # loopback-only HTTP server built on the standard library.
  module Gui
    # A deliberately small HTTP/1.1 server. It binds to the loopback interface
    # only, so it is never reachable from the network, and it speaks just enough
    # HTTP for one local browser: GET, POST, keep-alive and byte ranges.
    #
    # One thread waits on every open socket at once and reads whatever arrives,
    # and a connection goes to a worker only once a whole request is buffered.
    # So neither a browser's idle keep-alive sockets nor a client that sends its
    # request a byte at a time can tie up the pool: a worker never waits for a
    # client to send, and waits for one to receive only so long.
    class Server
      HOST = "127.0.0.1"
      WORKERS = 6
      MAX_CONNECTIONS = 256 # every open socket: arriving, idle, queued or being answered
      MAX_REQUESTS_PER_CONNECTION = 1_000
      KEEP_ALIVE_SECONDS = 65 # an idle connection is closed after this
      READ_TIMEOUT = 15       # a request must arrive in full within this of its first byte
      WRITE_TIMEOUT = 30      # a client that takes no bytes for this long is dropped
      SHUTDOWN_SECONDS = 3    # what requests still being answered get, in all, on stop
      POLL_SECONDS = 1.0      # the longest the event loop sleeps between deadline checks
      ACCEPT_BACKOFF = 0.1    # how long to leave the listener alone when out of descriptors
      # Descriptors kept back from connections for the listener, the wake-up
      # pipe, the standard streams, the files being streamed and whatever else
      # the program opens. A quarter of a very low limit, at most this many.
      FD_RESERVE = 64
      STREAM_CHUNK = 64 * 1024

      STATUS_TEXT = {
        200 => "OK", 206 => "Partial Content",
        400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 408 => "Request Timeout", 409 => "Conflict",
        413 => "Payload Too Large", 415 => "Unsupported Media Type", 416 => "Range Not Satisfiable",
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

      # The limits are keywords so that tests can shrink them; the defaults are
      # what the program runs with.
      def initialize(port: 0, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT,
                     keep_alive: KEEP_ALIVE_SECONDS, max_connections: MAX_CONNECTIONS,
                     shutdown_timeout: SHUTDOWN_SECONDS)
        @requested_port = port
        @read_timeout = read_timeout
        @write_timeout = write_timeout
        @keep_alive = keep_alive
        @max_connections = within_descriptor_limit(max_connections)
        @shutdown_timeout = shutdown_timeout
        @lock = Mutex.new
        @open = {}             # every open connection, wherever it is (guarded by @lock)
        @parked = {}           # socket => connection the event loop waits on (its own)
        @ready = Queue.new     # connections with a whole request, for the workers
        @returned = Queue.new  # connections the workers hand back to the event loop
        @accept_paused_until = nil
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
        close(@listener)
        WORKERS.times { @ready.push(:stop) }
        finish(workers) if workers
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

      # The connection limit only protects anyone if it is reached before the
      # process runs out of descriptors: past that, accept fails before any
      # idle connection is asked to make way, and the page is locked out. On
      # macOS a shell's default limit is 256, so the limit is cut to fit.
      def within_descriptor_limit(requested)
        return requested unless defined?(Process::RLIMIT_NOFILE) # Windows has no such limit

        soft, = Process.getrlimit(Process::RLIMIT_NOFILE)
        [requested, soft - [FD_RESERVE, soft / 4].min].min
      rescue NotImplementedError, SystemCallError
        requested
      end

      # Waits on the listener, the wake-up pipe and every parked socket at once.
      def event_loop
        while @running
          adopt_returned
          due = expire_overdue
          (wait_for_activity(due) || []).each do |io|
            if io.equal?(@listener) then accept_connection
            elsif io.equal?(@wake_reader) then drain_wake
            elsif (connection = @parked[io]) then receive(connection)
            end
          end
        end
      end

      # Sleeps until something is readable or the next deadline falls due. The
      # listener sits out while accepting is paused.
      def wait_for_activity(due)
        watched = [@wake_reader, *@parked.keys]
        if @accept_paused_until && now < @accept_paused_until
          due = [due, @accept_paused_until].min
        else
          @accept_paused_until = nil
          watched << @listener
        end
        IO.select(watched, nil, nil, [due - now, 0].max)&.first
      rescue IOError, SystemCallError
        @running = false
        nil
      end

      def accept_connection
        socket = @listener.accept_nonblock(exception: false)
        admit(socket) unless socket == :wait_readable
      rescue Errno::EMFILE, Errno::ENFILE
        # Out of descriptors short of the connection limit — something else
        # holds more of them than was reserved. As at the limit, the connection
        # idle the longest makes way, and the newcomer, still in the backlog, is
        # accepted on the next pass.
        evict_idlest || pause_accepting
      rescue Errno::ENOBUFS, Errno::ENOMEM
        pause_accepting
      rescue IOError, SystemCallError
        nil
      end

      # The connection stays in the backlog, so the listener stays readable and
      # selecting it again at once would spin a core until accepting can work.
      # It is left out of the set for a moment instead.
      def pause_accepting
        @accept_paused_until = now + ACCEPT_BACKOFF
      end

      # Every connection counts against one limit, so neither the sockets the
      # event loop waits on nor the queue in front of the workers can grow past
      # it. At the limit, the connection idle the longest makes way: a browser
      # simply reconnects when it needs one again, whereas refusing the
      # newcomer would lock the page out. Only when no connection is idle is the
      # newcomer turned away.
      def admit(socket)
        return close(socket) unless open_count < @max_connections || evict_idlest

        no_delay(socket)
        connection = Connection.new(socket)
        @lock.synchronize { @open[connection] = true }
        park(connection)
      end

      def evict_idlest
        idlest = @parked.each_value.reject(&:receiving?).min_by(&:idle_since)
        return false if idlest.nil?

        @parked.delete(idlest.socket)
        release(idlest)
        true
      end

      def open_count
        @lock.synchronize { @open.size }
      end

      # A response leaves in as few writes as possible, but whatever is left
      # (the start of a streamed file, say) must not wait on Nagle's algorithm
      # for the client's delayed ACK — some 40 ms on a reused connection.
      def no_delay(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue IOError, SystemCallError
        nil
      end

      # Reads what has arrived; a whole request — or one that must be refused —
      # becomes a job for a worker.
      def receive(connection)
        case connection.receive
        when :ready
          @parked.delete(connection.socket)
          @ready.push(connection)
        when :closed
          @parked.delete(connection.socket)
          release(connection)
        end
      end

      def park(connection)
        connection.touch
        @parked[connection.socket] = connection
      end

      # Connections whose response is out and whose next request is not whole.
      def adopt_returned
        park(@returned.pop) until @returned.empty?
      end

      # A request must arrive in full within the read timeout of its first byte,
      # however steadily its bytes trickle in; an idle connection is kept for
      # the keep-alive period. Returns when the next deadline falls due.
      def expire_overdue
        current = now
        due = current + POLL_SECONDS
        @parked.values.each do |connection|
          deadline = deadline_of(connection)
          if deadline > current
            due = deadline if deadline < due
          else
            @parked.delete(connection.socket)
            connection.receiving? ? time_out(connection) : release(connection)
          end
        end
        due
      end

      def deadline_of(connection)
        return connection.started_at + @read_timeout if connection.receiving?

        connection.idle_since + @keep_alive
      end

      # The event loop must never wait on a client, so the 408 gets a single
      # non-blocking write: it is small enough to fit, and if it does not, the
      # client was not listening anyway.
      def time_out(connection)
        response = Response.text("The request took too long to arrive.", status: 408)
        connection.socket.write_nonblock(message(response, keep_alive: false), exception: false)
      rescue IOError, SystemCallError
        nil
      ensure
        release(connection)
      end

      def release(connection)
        @lock.synchronize { @open.delete(connection) }
        close(connection.socket)
      end

      # Lets the event loop rebuild its socket set the moment a worker hands a
      # connection back, instead of waiting for the next poll.
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

      # One deadline for all the workers, not one each, so a stop takes at most
      # the shutdown timeout however many of them are busy.
      def finish(workers)
        deadline = now + @shutdown_timeout
        workers.each { |worker| worker.join([deadline - now, 0].max) }
      end

      # Closing every socket also ends any write a worker is still stuck in.
      def shut_down
        close(@listener)
        close(@wake_reader)
        close(@wake_writer)
        connections = @lock.synchronize { @open.keys.tap { @open.clear } }
        connections.each { |connection| close(connection.socket) }
        @parked.clear
      end

      # --- workers ------------------------------------------------------------

      def worker_loop(app)
        while (connection = @ready.pop) != :stop
          # Once the server is stopping, what is still queued is dropped rather
          # than started.
          @running ? serve(app, connection) : release(connection)
        end
      end

      def serve(app, connection)
        request = connection.take_request
        response = app.call(request)
        keep_alive = keep_alive?(connection, request)
        return release(connection) unless write(connection.socket, response, keep_alive: keep_alive) && keep_alive

        carry_on(connection)
      rescue RequestError => e
        write(connection.socket, Response.text(e.message, status: e.status), keep_alive: false)
        release(connection)
      rescue StandardError => e
        warn("file_organizer: GUI request failed: #{e.class}: #{e.message}")
        release(connection)
      end

      # Anything already buffered is the start of the next, pipelined, request.
      # If it is whole it goes straight back in the queue — no new bytes will
      # arrive to wake the event loop for it — and otherwise the event loop
      # waits for the rest.
      def carry_on(connection)
        case connection.advance
        when :ready then @ready.push(connection)
        when :closed then release(connection)
        else
          @returned.push(connection)
          wake
        end
      end

      def keep_alive?(connection, request)
        @running && request.keep_alive? && connection.requests < MAX_REQUESTS_PER_CONNECTION
      end

      # Returns false when the client hung up or stopped reading, so the
      # connection is dropped.
      def write(socket, response, keep_alive:)
        return write_stream(socket, response, keep_alive) if response.stream?

        send_all(socket, message(response, keep_alive: keep_alive))
      rescue IOError, SystemCallError
        false
      end

      # The file is opened before anything is sent, and without following a
      # link, so the bytes served are those of the file that was inspected —
      # and a file that vanished in between still gets a proper answer.
      def write_stream(socket, response, keep_alive)
        file = open_for_streaming(response.file_path)
        if file.nil?
          return write(socket, Response.text("That file is no longer there.", status: 404), keep_alive: keep_alive)
        end

        begin
          send_all(socket, head(response, keep_alive)) &&
            send_file(socket, file, response.file_offset, response.file_length)
        ensure
          file.close
        end
      end

      def open_for_streaming(path)
        SafeFile.open(path)
      rescue IOError, SystemCallError
        nil
      end

      # In chunks, each written against the same deadline. If the file shrank
      # meanwhile, fewer bytes than announced were sent, so this returns false
      # and the connection is closed rather than left waiting for the rest.
      def send_file(socket, file, offset, length)
        file.seek(offset)
        chunk = String.new(capacity: STREAM_CHUNK, encoding: Encoding::BINARY)
        while length.positive?
          return false unless file.read([STREAM_CHUNK, length].min, chunk) && send_all(socket, chunk)

          length -= chunk.bytesize
        end
        true
      end

      # Never blocks for good: a client that takes no bytes for the write
      # timeout — a paused video, or pipelined requests whose answers are never
      # read — loses its connection instead of keeping a worker. Returns false
      # when that happens.
      def send_all(socket, data)
        until data.empty?
          written = socket.write_nonblock(data, exception: false)
          if written == :wait_writable
            return false unless socket.wait_writable(@write_timeout)
          else
            data = data.byteslice(written, data.bytesize - written)
          end
        end
        true
      end

      # Head and body in one write, so the body does not wait on the client's
      # delayed ACK of the head.
      def message(response, keep_alive:)
        head(response, keep_alive).b << response.body.b
      end

      # "Connection: close" whenever the server is about to close, so the client
      # does not send another request on a connection that is going away.
      def head(response, keep_alive = true)
        headers = BASE_HEADERS.merge(response.headers)
        headers["Content-Length"] = response.content_length.to_s
        headers["Connection"] = keep_alive ? "keep-alive" : "close"
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

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
