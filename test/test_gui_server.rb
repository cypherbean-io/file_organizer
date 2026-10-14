# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/file_organizer/gui"
require "json"
require "socket"

# A real Gui::Server on an ephemeral loopback port, serving a stub app and
# spoken to with raw HTTP over TCPSocket, so what is tested is exactly what a
# browser would see on the wire.
module ServerHarness
  include OrganizerTest

  Reply = Struct.new(:status, :reason, :header_lines, :headers, :body)

  # Stands in for Gui::App: remembers every request it is handed and answers
  # with whatever the test asked for — an echo of the request by default.
  class StubApp
    attr_reader :requests
    attr_writer :handler

    def initialize
      @requests = Queue.new
      @handler = ->(request) { FileOrganizer::Gui::Response.text("#{request.method} #{request.target}") }
    end

    def call(request)
      @requests << request
      @handler.call(request)
    end
  end

  def setup
    super
    @sockets = []
    @app = StubApp.new
    @threads_before = Thread.list
    @descriptors_before = open_descriptors
    @server = Gui::Server.new(port: 0, **server_options).start
    @thread = Thread.new do
      @server.run(@app)
      :stopped
    rescue Interrupt # what Ctrl-C raises in the thread running the server
      :interrupted
    end
  end

  # Test classes that need tighter limits than the defaults override this.
  def server_options
    {}
  end

  def teardown
    # Clients first, so a worker still writing to one fails at once instead of
    # holding up the server's shutdown.
    @sockets.each { |socket| socket.close unless socket.closed? }
    @server.stop
    stopped = @thread.join(5)
    @thread.kill unless stopped
    lingering = threads_left_running
    super
    assert stopped, "the server thread did not stop within 5 s"
    assert_empty lingering, "threads outlived the server"
    return if @descriptors_before.nil?

    assert_operator open_descriptors, :<=, @descriptors_before, "file descriptors leaked"
  end

  # A worker still finishing its last job may outlive run by a moment.
  def threads_left_running(seconds = 2)
    deadline = now + seconds
    loop do
      alive = Thread.list - @threads_before
      return alive if alive.empty? || now > deadline

      sleep 0.01
    end
  end

  def open_descriptors
    Dir.children("/proc/self/fd").size if File.directory?("/proc/self/fd")
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_until(what, seconds = 3)
    deadline = now + seconds
    until yield
      flunk("timed out waiting until #{what}") if now > deadline
      sleep 0.01
    end
  end

  def respond(&handler)
    @app.handler = handler
  end

  # Streams +file+ for /media and echoes anything else, so a follow-up request
  # can show the connection is still in step.
  def serve_file(file, offset:, length:, total:)
    respond do |request|
      next Gui::Response.text("next") unless request.path == "/media"

      Gui::Response.file(file, content_type: "application/octet-stream", offset: offset, length: length, total: total)
    end
  end

  def connect
    socket = TCPSocket.new(Gui::Server::HOST, @server.port)
    track(socket)
  end

  def track(socket)
    socket.binmode
    # A hung server fails the test instead of hanging it (IO#timeout is 3.2+).
    socket.timeout = 5 if socket.respond_to?(:timeout=)
    @sockets << socket
    socket
  end

  def request(method = "GET", target = "/", headers: {}, body: nil)
    lines = ["#{method} #{target} HTTP/1.1", "Host: 127.0.0.1:#{@server.port}"]
    headers = headers.merge("Content-Length" => body.bytesize) if body
    headers.each { |name, value| lines << "#{name}: #{value}" }
    "#{lines.join("\r\n")}\r\n\r\n#{body}".b
  end

  # Sends +raw+ on a new connection; returns [reply, socket].
  def exchange(raw)
    socket = connect
    socket.write(raw)
    [read_reply(socket), socket]
  end

  # Reads exactly one response: the head, then Content-Length bytes of body
  # (fewer only if the server closes the connection first).
  def read_reply(socket)
    status_line = socket.gets("\r\n")
    return nil if status_line.nil?

    version, status, reason = status_line.chomp("\r\n").split(" ", 3)
    assert_equal "HTTP/1.1", version
    lines = []
    while (line = socket.gets("\r\n")) && line != "\r\n"
      lines << line.chomp("\r\n")
    end
    headers = lines.to_h do |header|
      name, value = header.split(": ", 2)
      [name.downcase, value]
    end
    length = Integer(headers.fetch("content-length"))
    body = length.zero? ? "".b : socket.read(length).to_s
    Reply.new(Integer(status), reason, lines, headers, body)
  end

  def closed_by_server?(socket)
    socket.read(1).nil?
  rescue Errno::ECONNRESET, Errno::EPIPE
    true
  end

  # The app records a request before answering it, so once the reply is in,
  # so is the request.
  def received
    wait_until("the app has a request", 1) { !@app.requests.empty? }
    @app.requests.pop
  end
end

class TestGuiServerHttp < Minitest::Test
  include ServerHarness

  def test_answers_a_get_with_its_length_and_the_hardening_headers
    reply, = exchange(request("GET", "/hello?name=x"))

    assert_equal 200, reply.status
    assert_equal "OK", reply.reason
    assert_equal "GET /hello?name=x\n", reply.body
    assert_equal reply.body.bytesize.to_s, reply.headers["content-length"]
    assert_equal "text/plain; charset=utf-8", reply.headers["content-type"]
    assert_equal "nosniff", reply.headers["x-content-type-options"]
    assert_equal "DENY", reply.headers["x-frame-options"]
    Gui::Server::BASE_HEADERS.each do |name, value|
      assert_equal value, reply.headers[name.downcase], name
    end
  end

  def test_hands_the_app_a_parsed_request
    exchange(request("GET", "/api/files?t=abc%20d", headers: { "X-Session-Token" => "  secret  " }))
    seen = received

    assert_equal "GET", seen.method
    assert_equal "/api/files", seen.path
    assert_equal "abc d", seen.param("t")
    assert_equal "secret", seen.header("x-session-token") # names lowercased, values trimmed
    assert_equal "127.0.0.1:#{@server.port}", seen.header("host")
  end

  def test_post_body_reaches_the_app
    respond { |request| Gui::Response.json(request.json) }
    payload = { "id" => "abc", "name" => "né — 日本.txt" }
    reply, = exchange(request("POST", "/api/rename", body: JSON.generate(payload)))

    assert_equal 200, reply.status
    assert_equal payload, JSON.parse(reply.body.dup.force_encoding(Encoding::UTF_8))
  end

  # Regression-style: a length counted in characters would cut a non-ASCII
  # body short and leave its tail to be misread as the next response.
  def test_content_length_counts_bytes_not_characters
    respond do |request|
      request.path == "/json" ? Gui::Response.json({ "name" => "café — 日本" }) : Gui::Response.text("next")
    end
    reply, socket = exchange(request("GET", "/json"))

    assert_equal reply.body.bytesize, Integer(reply.headers["content-length"])
    assert_equal({ "name" => "café — 日本" }, JSON.parse(reply.body.dup.force_encoding(Encoding::UTF_8)))
    socket.write(request("GET", "/after"))
    assert_equal "next\n", read_reply(socket).body
  end

  def test_the_server_computes_content_length_whatever_the_app_claims
    respond { Gui::Response.new(status: 200, headers: { "Content-Length" => "999" }, body: "short") }
    reply, = exchange(request)

    assert_equal "5", reply.headers["content-length"]
    assert_equal 1, reply.header_lines.count { |line| line.downcase.start_with?("content-length:") }
    assert_equal "short", reply.body
  end

  def test_keeps_the_connection_open_for_further_requests
    socket = connect
    socket.write(request("GET", "/first"))
    first = read_reply(socket)
    socket.write(request("GET", "/second"))
    second = read_reply(socket)

    assert_equal "GET /first\n", first.body
    assert_equal "GET /second\n", second.body
    assert_equal "keep-alive", first.headers["connection"]
    assert_equal "keep-alive", second.headers["connection"]
  end

  # Regression: with the head and body written separately and Nagle's
  # algorithm on, every response on a reused connection waited ~40 ms for the
  # client's delayed ACK — 20 requests took most of a second.
  def test_responses_on_a_reused_connection_are_not_held_back
    socket = connect
    started = now
    20.times do |index|
      socket.write(request("GET", "/#{index}"))
      assert_equal "GET /#{index}\n", read_reply(socket).body
    end

    assert_operator now - started, :<, 0.5
  end

  # Regression: a pipelined request is already in the connection's buffer, so
  # the event loop never sees it arrive; the worker has to pick it up itself.
  def test_answers_pipelined_requests_in_order
    socket = connect
    socket.write(request("GET", "/one") + request("POST", "/two", body: "x" * 10) + request("GET", "/three"))

    assert_equal ["GET /one\n", "POST /two\n", "GET /three\n"], Array.new(3) { read_reply(socket).body }
    assert_equal ["x" * 10], [received, received, received].select(&:post?).map(&:body)
  end

  def test_tolerates_up_to_two_stray_blank_lines_before_a_request
    reply, = exchange("\r\n\r\n".b + request("GET", "/after-blanks"))
    assert_equal "GET /after-blanks\n", reply.body
  end

  def test_connection_close_is_honoured
    ["close", "Close"].each do |value|
      reply, socket = exchange(request("GET", "/bye", headers: { "Connection" => value }))

      assert_equal 200, reply.status
      assert_equal "GET /bye\n", reply.body
      assert_equal "close", reply.headers["connection"]
      assert closed_by_server?(socket), "Connection: #{value} must close the connection"
    end
  end

  def test_closes_the_connection_after_the_request_limit
    socket = connect
    limit = Gui::Server::MAX_REQUESTS_PER_CONNECTION
    # Pipelined in one write, so the test does not pay a round trip per request.
    socket.write(Array.new(limit) { |index| request("GET", "/#{index}") }.join)
    replies = Array.new(limit) { read_reply(socket) }

    assert_equal Array.new(limit) { |index| "GET /#{index}\n" }, replies.map(&:body)
    assert_equal ["keep-alive"], replies[0...-1].map { |reply| reply.headers["connection"] }.uniq
    assert_equal "close", replies.last.headers["connection"], "the last response must announce the close"
    assert closed_by_server?(socket), "the connection outlived MAX_REQUESTS_PER_CONNECTION"
  end

  # Regression: response headers are assembled into the head verbatim, so a
  # CR or LF in a value would let it start a header — or a body — of its own.
  def test_strips_cr_and_lf_from_header_values
    respond do |request|
      next Gui::Response.text("next") if request.path == "/next"

      Gui::Response.new(status: 200, body: "ok",
                        headers: { "X-Note" => "one\r\nSet-Cookie: injected=1", "X-Other" => "a\rb\nc\r\n\r\nd" })
    end
    reply, socket = exchange(request)

    assert_equal "oneSet-Cookie: injected=1", reply.headers["x-note"]
    assert_equal "abcd", reply.headers["x-other"]
    refute reply.headers.key?("set-cookie")
    assert_equal "ok", reply.body
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  def test_a_failing_app_drops_only_its_own_connection
    respond do |request|
      raise "boom" if request.path == "/boom"

      Gui::Response.text("fine")
    end
    socket = connect
    _, err = capture_io do
      socket.write(request("GET", "/boom"))
      assert closed_by_server?(socket)
    end

    assert_match(/GUI request failed: RuntimeError: boom/, err)
    assert_equal "fine\n", exchange(request("GET", "/ok")).first.body
  end
end

class TestGuiServerRequestLimits < Minitest::Test
  include ServerHarness

  # Every refusal is answered, closes its connection, and never reaches the app.
  def assert_refused(raw, status, message)
    reply, socket = exchange(raw)

    assert_equal status, reply.status
    assert_equal Gui::Server::STATUS_TEXT.fetch(status), reply.reason
    assert_match message, reply.body
    assert_equal "close", reply.headers["connection"]
    assert closed_by_server?(socket), "a refused request must close its connection"
    assert @app.requests.empty?, "a refused request must never reach the app"
    reply
  end

  def test_malformed_request_line_is_a_bad_request
    assert_refused("GARBAGE\r\n\r\n", 400, /Malformed request line/)
    assert_refused("GET /\r\n\r\n", 400, /Malformed request line/)
  end

  def test_more_than_two_blank_lines_before_a_request_is_a_bad_request
    assert_refused("\r\n\r\n\r\n".b + request, 400, /Malformed request line/)
  end

  def test_http_versions_other_than_1_x_are_refused
    assert_refused("GET / HTTP/2.0\r\n\r\n", 505, /Only HTTP\/1\.x/)
    assert_refused("GET / SPDY/3\r\n\r\n", 505, /Only HTTP\/1\.x/)
  end

  def test_header_without_a_colon_is_a_bad_request
    assert_refused("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n", 400, /Malformed header/)
  end

  def test_header_line_over_8_kib_is_refused
    # The newline never comes: the line is refused once 8 KiB of it is buffered.
    long = "X-Big: #{"a" * (Gui::Connection::MAX_LINE_BYTES + 1)}"
    assert_refused("GET / HTTP/1.1\r\n#{long}", 431, /too long/)
  end

  def test_request_line_over_8_kib_is_refused
    assert_refused("GET /#{"a" * (Gui::Connection::MAX_LINE_BYTES + 1)}", 431, /too long/)
  end

  # Regression: the length was checked only while no newline was buffered, so
  # an over-long line that arrived in one read, newline and all, got through.
  def test_over_long_lines_arriving_whole_are_refused
    long = "a" * (Gui::Connection::MAX_LINE_BYTES * 3)
    assert_refused(request(headers: { "X-Big" => long }), 431, /too long/)
    assert_refused(request("GET", "/#{long}"), 431, /too long/)
  end

  # The limit counts every byte before the newline, the CR included.
  def test_a_line_of_exactly_8_kib_is_accepted_and_one_byte_more_is_not
    value = "a" * (Gui::Connection::MAX_LINE_BYTES - "X-Edge: \r".bytesize)
    reply, = exchange(request(headers: { "X-Edge" => value }))

    assert_equal 200, reply.status
    assert_equal value, received.header("x-edge")
    assert_refused(request(headers: { "X-Edge" => "#{value}a" }), 431, /too long/)
  end

  # Every line may be within its limit and the head still too big in all.
  def test_headers_over_64_kib_in_all_are_refused
    headers = (1..9).to_h { |index| ["X-Part-#{index}", "a" * 8000] }
    assert_refused(request(headers: headers), 431, /headers too large/)
  end

  def test_more_than_64_headers_are_refused
    headers = (1..64).to_h { |index| ["X-Header-#{index}", "v"] } # 65 with Host
    assert_refused(request(headers: headers), 431, /Too many request headers/)
  end

  # Regression: the blank line that ends the headers used up one of the 64
  # turns, so exactly 64 headers were refused.
  def test_exactly_64_headers_are_accepted
    headers = (1..63).to_h { |index| ["X-Header-#{index}", "v"] } # 64 with Host
    reply, = exchange(request(headers: headers))

    assert_equal 200, reply.status
    assert_equal 64, received.headers.size
  end

  def test_a_modest_number_of_headers_is_accepted
    headers = (1..40).to_h { |index| ["X-Header-#{index}", "v"] }
    reply, = exchange(request(headers: headers))

    assert_equal 200, reply.status
    assert_equal "v", received.header("x-header-40")
  end

  def test_body_over_64_kib_is_refused_before_it_is_read
    assert_refused("POST / HTTP/1.1\r\nContent-Length: #{Gui::Connection::MAX_BODY_BYTES + 1}\r\n\r\n",
                   413, /too large/)
    assert_refused("POST / HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\n", 413, /too large/)
  end

  def test_body_of_exactly_64_kib_is_accepted
    body = "y" * Gui::Connection::MAX_BODY_BYTES
    reply, = exchange(request("POST", "/upload", body: body))

    assert_equal 200, reply.status
    assert_equal body, received.body
  end

  def test_invalid_content_length_is_a_bad_request
    ["-1", "12abc", "1, 1", "99999999999", ""].each do |value|
      assert_refused("POST / HTTP/1.1\r\nContent-Length: #{value}\r\n\r\n", 400, /Invalid Content-Length/)
    end
  end

  def test_chunked_bodies_are_refused
    assert_refused("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
                   400, /Chunked bodies are not supported/)
  end

  def test_unsupported_methods_are_refused
    %w[PUT DELETE HEAD get].each do |method|
      assert_refused("#{method} / HTTP/1.1\r\nContent-Length: 0\r\n\r\n", 405, /Method not allowed/)
    end
  end

  def test_a_body_cut_short_is_a_bad_request
    socket = connect
    socket.write("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
    socket.close_write
    reply = read_reply(socket)

    assert_equal 400, reply.status
    assert_match(/Truncated request body/, reply.body)
    assert_equal "close", reply.headers["connection"]
    assert @app.requests.empty?
  end

  def test_headers_cut_short_are_a_bad_request
    socket = connect
    socket.write("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    socket.close_write
    reply = read_reply(socket)

    assert_equal 400, reply.status
    assert_match(/Unexpected end of headers/, reply.body)
  end

  def test_a_client_that_leaves_without_a_word_is_dropped_quietly
    socket = connect
    socket.close
    # The server is still answering everyone else.
    assert_equal 200, exchange(request).first.status
  end
end

class TestGuiServerConcurrency < Minitest::Test
  include ServerHarness

  # Regression-style: a worker per connection would let a browser's idle
  # keep-alive sockets, or a client that stalls mid-request, starve the pool.
  def test_idle_and_half_sent_connections_do_not_block_other_clients
    idle = Array.new(Gui::Server::WORKERS + 2) { connect }
    stalled = Array.new(Gui::Server::WORKERS - 1) do |index|
      connect.tap { |socket| socket.write("GET /stalled-#{index} HTTP/1.1\r\nHost: 127.0.0.1\r\n") }
    end
    sleep 0.2 # let the event loop take in each partial request

    started = now
    reply, = exchange(request("GET", "/fast"))
    elapsed = now - started

    assert_equal "GET /fast\n", reply.body
    assert_operator elapsed, :<, 2, "another client was kept waiting behind stalled ones"

    stalled.each_with_index do |socket, index|
      socket.write("\r\n")
      assert_equal "GET /stalled-#{index}\n", read_reply(socket).body
    end
    idle.each_with_index do |socket, index|
      socket.write(request("GET", "/idle-#{index}"))
      assert_equal "GET /idle-#{index}\n", read_reply(socket).body
    end
  end

  def test_serves_concurrent_clients
    replies = Array.new(12) do |index|
      Thread.new { exchange(request("GET", "/client-#{index}")).first.body }
    end.map(&:value)

    assert_equal Array.new(12) { |index| "GET /client-#{index}\n" }, replies
  end

  def test_stop_closes_idle_keep_alive_connections
    reply, socket = exchange(request)
    assert_equal 200, reply.status

    @server.stop
    assert @thread.join(5), "run did not return after stop"
    assert closed_by_server?(socket)
  end

  # The page's Quit button stops the server from inside a request.
  def test_stop_from_inside_a_request_still_answers_it
    respond do
      @server.stop
      Gui::Response.text("bye")
    end
    reply, socket = exchange(request("POST", "/api/quit", body: "{}"))

    assert_equal "bye\n", reply.body
    assert_equal "close", reply.headers["connection"], "a stopping server takes no further request"
    assert closed_by_server?(socket)
    assert @thread.join(5), "run did not return after stop"
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new(Gui::Server::HOST, @server.port).close }
  end

  def test_addresses_name_the_loopback_port_it_bound
    port = @server.port

    assert_operator port, :>, 0
    assert_equal "http://127.0.0.1:#{port}", @server.origin
    assert_equal "http://127.0.0.1:#{port}/?t=x", @server.url("/?t=x")
    assert_equal ["127.0.0.1:#{port}", "localhost:#{port}"], @server.hosts
    assert_equal 200, exchange(request).first.status
  end
end

class TestGuiServerStreaming < Minitest::Test
  include ServerHarness

  def test_streams_exactly_the_requested_byte_range
    content = (0..255).map(&:chr).join.b * 4
    file = write("media.bin", content)
    serve_file(file, offset: 100, length: 300, total: content.bytesize)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal 206, reply.status
    assert_equal "Partial Content", reply.reason
    assert_equal "300", reply.headers["content-length"]
    assert_equal "bytes 100-399/1024", reply.headers["content-range"]
    assert_equal "default-src 'none'; sandbox", reply.headers["content-security-policy"]
    assert_equal content.byteslice(100, 300), reply.body
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  def test_streams_a_whole_large_file
    content = Random.new(42).bytes(3 * 1024 * 1024 + 17)
    file = write("big.bin", content)
    serve_file(file, offset: 0, length: content.bytesize, total: content.bytesize)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal 200, reply.status
    refute reply.headers.key?("content-range")
    assert_equal content.bytesize, reply.body.bytesize
    assert_equal content, reply.body
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  # The head and the file go out in separate writes, so without TCP_NODELAY
  # the file would wait for the client's delayed ACK of the head.
  def test_streamed_responses_on_a_reused_connection_are_not_held_back
    file = write("clip.bin", "x" * 1000)
    serve_file(file, offset: 0, length: 1000, total: 1000)
    socket = connect
    started = now
    20.times do
      socket.write(request("GET", "/media"))
      assert_equal 1000, read_reply(socket).body.bytesize
    end

    assert_operator now - started, :<, 0.5
  end

  def test_streams_an_empty_file
    file = write("empty.bin", "")
    serve_file(file, offset: 0, length: 0, total: 0)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal 200, reply.status
    assert_equal "", reply.body
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  # Regression: the file is opened through SafeFile, so a link swapped in after
  # the app looked at the path is refused rather than followed.
  def test_a_symlink_gets_404_and_its_target_is_not_served
    secret = write("secret.txt", "not for the page\n")
    File.symlink(secret, path("clip.bin"))
    serve_file(path("clip.bin"), offset: 0, length: 17, total: 17)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal 404, reply.status
    assert_equal "That file is no longer there.\n", reply.body
    assert_equal "nosniff", reply.headers["x-content-type-options"]
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  def test_a_file_that_vanished_gets_404
    file = write("gone.bin", "soon gone")
    serve_file(file, offset: 0, length: 9, total: 9)
    File.delete(file)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal 404, reply.status
    assert_equal "That file is no longer there.\n", reply.body
    socket.write(request("GET", "/next"))
    assert_equal "next\n", read_reply(socket).body
  end

  # Fewer bytes than announced were sent, so the client must not be left
  # waiting for the rest on a connection that looks alive.
  def test_a_file_that_shrank_closes_the_connection_after_what_it_had
    file = write("shrunk.bin", "0123456789")
    serve_file(file, offset: 0, length: 100, total: 100)
    reply, socket = exchange(request("GET", "/media"))

    assert_equal "100", reply.headers["content-length"]
    assert_equal "0123456789", reply.body
    assert closed_by_server?(socket)
  end
end

class TestGuiServerWithoutStart < Minitest::Test
  def test_run_before_start_is_an_error
    error = assert_raises(FileOrganizer::Error) { FileOrganizer::Gui::Server.new.run(->(_request) {}) }
    assert_match(/not been started/, error.message)
  end
end

class TestGuiIds < Minitest::Test
  include FileOrganizer

  def assert_round_trip(name)
    id = Gui.encode_id(name)

    assert_match Gui::ID_PATTERN, id
    decoded = Gui.decode_id(id)
    assert_equal name.b, decoded.b
    assert_equal Encoding::UTF_8, decoded.encoding
    decoded
  end

  def test_round_trips_an_ordinary_name
    assert_equal "report 2024.pdf", assert_round_trip("report 2024.pdf")
  end

  def test_round_trips_a_unicode_name
    decoded = assert_round_trip("Café — 日本語 🎵.txt")

    assert_equal "Café — 日本語 🎵.txt", decoded
    assert decoded.valid_encoding?
  end

  def test_round_trips_a_name_that_is_not_valid_utf8
    name = "caf\xE9 \xFF\xFE.txt".b
    decoded = assert_round_trip(name)

    refute decoded.valid_encoding?
  end

  def test_ids_are_url_safe_and_unpadded
    # These bytes encode to "+/+/" and "/w==" in plain Base64.
    ["\xFB\xFF\xBF".b, "\xFF".b, "ab", "abc", "a" * 255].each do |name|
      id = Gui.encode_id(name)

      refute_match(%r{[+/=]}, id)
      assert_equal name.b, Gui.decode_id(id).b
    end
  end

  def test_encoding_leaves_the_name_alone
    name = "frozen é.txt"
    Gui.encode_id(name)

    assert_equal Encoding::UTF_8, name.encoding
    assert_equal "frozen é.txt", name
  end

  def test_decode_rejects_anything_but_a_string
    [nil, 42, :name, ["YQ"], { "id" => "YQ" }].each do |value|
      assert_nil Gui.decode_id(value), value.inspect
    end
  end

  def test_decode_rejects_characters_outside_url_safe_base64
    ["", "YQ==", "a+b", "a/b", "a b", "YQ\n", "\nYQ", "../YQ", "a.b", "é", "YQ\0"].each do |id|
      assert_nil Gui.decode_id(id), id.inspect
    end
  end

  def test_decode_rejects_over_long_ids
    assert_nil Gui.decode_id("A" * 701)
    refute_nil Gui.decode_id("A" * 700)
  end
end
