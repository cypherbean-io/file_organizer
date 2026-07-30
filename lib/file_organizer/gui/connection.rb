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

    # Buffered, timeout-bounded reading of HTTP requests from one client
    # socket. Every limit here exists so that a malformed or hostile request
    # cannot make the server allocate or wait without bound.
    class Connection
      MAX_LINE_BYTES = 8 * 1024
      MAX_HEADERS = 64
      MAX_BODY_BYTES = 64 * 1024
      READ_CHUNK = 32 * 1024
      READ_TIMEOUT = 15 # waiting for the rest of a request already arriving
      SUPPORTED_METHODS = %w[GET POST].freeze
      BLANK_LINE_LIMIT = 2

      attr_reader :socket, :requests

      def initialize(socket)
        @socket = socket
        @buffer = String.new(capacity: READ_CHUNK, encoding: Encoding::BINARY)
        @requests = 0
        touch
      end

      # True when the next request is already in the buffer (a pipelined one).
      def buffered?
        !@buffer.empty?
      end

      def touch
        @idle_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def idle_for
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - @idle_since
      end

      # Returns a Request, or nil when the client went away or fell silent.
      # Only ever called once data is already arriving, so the wait is bounded
      # by READ_TIMEOUT rather than by how long a browser keeps a socket open.
      def read_request
        line = request_line(READ_TIMEOUT)
        return nil if line.nil?

        @requests += 1

        method, target, version = line.split(" ", 3)
        raise RequestError.new(400, "Malformed request line.") if target.nil? || version.nil?
        raise RequestError.new(505, "Only HTTP/1.x is supported.") unless version.start_with?("HTTP/1.")

        headers = read_headers
        raise RequestError.new(400, "Chunked bodies are not supported.") if headers.key?("transfer-encoding")

        body = read_body(headers)
        raise RequestError.new(405, "Method not allowed.") unless SUPPORTED_METHODS.include?(method)

        Request.new(method: method, target: target, headers: headers, body: body)
      end

      private

      # Tolerates the stray blank lines some clients send between requests.
      def request_line(timeout)
        (BLANK_LINE_LIMIT + 1).times do
          line = read_line(timeout)
          return nil if line.nil?
          return line unless line.empty?
        end
        raise RequestError.new(400, "Malformed request line.")
      end

      def read_headers
        headers = {}
        MAX_HEADERS.times do
          line = read_line(READ_TIMEOUT)
          raise RequestError.new(400, "Unexpected end of headers.") if line.nil?
          return headers if line.empty?

          name, value = line.split(":", 2)
          raise RequestError.new(400, "Malformed header.") if value.nil?

          headers[name.strip.downcase] = value.strip
        end
        raise RequestError.new(431, "Too many request headers.")
      end

      def read_body(headers)
        declared = headers["content-length"]
        return "" if declared.nil?
        raise RequestError.new(400, "Invalid Content-Length.") unless declared.match?(/\A\d{1,10}\z/)

        length = declared.to_i
        raise RequestError.new(413, "Request body too large.") if length > MAX_BODY_BYTES
        return "" if length.zero?

        body = read_bytes(length)
        raise RequestError.new(400, "Truncated request body.") if body.nil?

        body.force_encoding(Encoding::UTF_8)
      end

      def read_line(timeout)
        loop do
          index = @buffer.index("\n".b)
          return @buffer.slice!(0, index + 1).chomp if index
          raise RequestError.new(431, "Request line too long.") if @buffer.bytesize > MAX_LINE_BYTES
          return nil unless fill(timeout)
        end
      end

      def read_bytes(count)
        return nil unless fill_until(count)

        @buffer.slice!(0, count)
      end

      def fill_until(count)
        while @buffer.bytesize < count
          return false unless fill(READ_TIMEOUT)
        end
        true
      end

      # Returns false once the client has closed or stopped sending.
      def fill(timeout)
        return false unless @socket.wait_readable(timeout)

        @buffer << @socket.read_nonblock(READ_CHUNK)
        true
      rescue IO::WaitReadable
        true
      rescue EOFError, SystemCallError, IOError
        false
      end
    end
  end
end
