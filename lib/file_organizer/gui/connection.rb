# frozen_string_literal: true

module FileOrganizer
  module Gui
    # A request that was refused before it could be dispatched.
    class RequestError < StandardError
      attr_reader :status

      def initialize(status, message)
        super(message)
        @status = status
      end
    end

    # One client socket and the request arriving on it. Bytes are read only
    # when the socket already has them, and parsed as they come, so nothing
    # here ever waits on the network: the server decides how long a client may
    # take. Every limit exists so that a malformed or hostile request cannot
    # make the server allocate without bound.
    #
    # A connection belongs to one thread at a time — the event loop while the
    # request arrives, then a worker while it is answered — so it needs no lock.
    class Connection
      MAX_LINE_BYTES = 8 * 1024   # bytes before a line's newline
      MAX_HEADERS = 64
      MAX_HEAD_BYTES = 64 * 1024  # request line and headers together
      MAX_BODY_BYTES = 64 * 1024
      READ_CHUNK = 32 * 1024
      SUPPORTED_METHODS = %w[GET POST].freeze
      BLANK_LINE_LIMIT = 2
      NEWLINE = "\n".b.freeze

      attr_reader :socket, :requests, :idle_since, :started_at

      def initialize(socket)
        @socket = socket
        @buffer = String.new(capacity: READ_CHUNK, encoding: Encoding::BINARY)
        @requests = 0
        @eof = false
        start_request
        touch
      end

      def touch
        @idle_since = now
      end

      # True while a request has begun to arrive but is not yet whole.
      def receiving?
        !@started_at.nil?
      end

      # Reads what the socket already holds, without waiting, and parses as far
      # as that goes. Returns what #advance does.
      #
      # While a request is incomplete the buffer holds at most one partial line
      # (MAX_LINE_BYTES) or a partial body (MAX_BODY_BYTES) plus one read, and
      # the lines already parsed are capped by MAX_HEAD_BYTES; and nothing is
      # read once a request is whole. So however a client paces its bytes, it
      # cannot make a connection hold much more than that.
      def receive
        data = @socket.read_nonblock(READ_CHUNK, exception: false)
        if data.nil?
          @eof = true
        elsif data != :wait_readable
          @buffer << data
        end
        advance
      rescue IOError, SystemCallError
        :closed # reset under us: there is no one left to answer
      end

      # Parses as much of the next request as is buffered, never touching the
      # socket:
      #   :ready   — a whole request, or a reason to refuse one, is in hand
      #   :pending — more bytes are needed
      #   :closed  — the client left without starting another request
      def advance
        return :ready if @request || @error

        until @request
          next if parse_step

          start_clock
          return out_of_bytes
        end
        :ready
      rescue RequestError => e
        @error = e
        :ready
      end

      # Hands over the request #advance completed — or raises the reason it was
      # refused, after which the connection is closed — and starts on the next.
      def take_request
        raise @error if @error

        request = @request
        start_request
        request
      end

      private

      def start_request
        @stage = :request_line
        @request = nil
        @blank_lines = 0
        @header_lines = 0
        @head_bytes = 0
        @headers = {}
        @started_at = nil
      end

      # Returns false when the buffer runs out before the step is complete.
      def parse_step
        case @stage
        when :request_line then parse_request_line
        when :headers then parse_header
        else parse_body
        end
      end

      # The server's read deadline runs from the first byte of a request. Stray
      # blank lines, which some clients send after a body, do not start one: a
      # connection with nothing more to come is idle, not slow.
      def start_clock
        @started_at ||= now unless @stage == :request_line && @buffer.empty?
      end

      def out_of_bytes
        return :pending unless @eof
        return :closed if @stage == :request_line

        raise RequestError.new(400, @stage == :headers ? "Unexpected end of headers." : "Truncated request body.")
      end

      # Tolerates the stray blank lines some clients send between requests.
      def parse_request_line
        line = take_line
        return false if line.nil?

        if line.empty?
          @blank_lines += 1
          raise RequestError.new(400, "Malformed request line.") if @blank_lines > BLANK_LINE_LIMIT

          return true
        end

        @requests += 1
        @method, @target, version = line.split(" ", 3)
        raise RequestError.new(400, "Malformed request line.") if @target.nil? || version.nil?
        raise RequestError.new(505, "Only HTTP/1.x is supported.") unless version.start_with?("HTTP/1.")

        @stage = :headers
        true
      end

      def parse_header
        line = take_line
        return false if line.nil?
        return end_of_head if line.empty?
        raise RequestError.new(431, "Too many request headers.") if @header_lines >= MAX_HEADERS

        name, value = line.split(":", 2)
        raise RequestError.new(400, "Malformed header.") if value.nil?

        @header_lines += 1
        @headers[name.strip.downcase] = value.strip
        true
      end

      def end_of_head
        raise RequestError.new(400, "Chunked bodies are not supported.") if @headers.key?("transfer-encoding")

        @body_length = declared_length
        @stage = :body
        true
      end

      def declared_length
        declared = @headers["content-length"]
        return 0 if declared.nil?
        raise RequestError.new(400, "Invalid Content-Length.") unless declared.match?(/\A\d{1,10}\z/)

        length = declared.to_i
        raise RequestError.new(413, "Request body too large.") if length > MAX_BODY_BYTES

        length
      end

      def parse_body
        return false if @buffer.bytesize < @body_length

        body = @body_length.zero? ? "" : @buffer.slice!(0, @body_length).force_encoding(Encoding::UTF_8)
        raise RequestError.new(405, "Method not allowed.") unless SUPPORTED_METHODS.include?(@method)

        @request = Request.new(method: @method, target: @target, headers: @headers, body: body)
        true
      end

      # A line is too long once more than MAX_LINE_BYTES precede its newline —
      # whether that newline is still to come, or arrived in the same read as
      # the whole line.
      def take_line
        newline = @buffer.index(NEWLINE)
        if newline.nil?
          raise RequestError.new(431, "Request line too long.") if @buffer.bytesize > MAX_LINE_BYTES

          return nil
        end
        raise RequestError.new(431, "Request line too long.") if newline > MAX_LINE_BYTES

        @head_bytes += newline + 1
        raise RequestError.new(431, "Request headers too large.") if @head_bytes > MAX_HEAD_BYTES

        @buffer.slice!(0, newline + 1).chomp
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
