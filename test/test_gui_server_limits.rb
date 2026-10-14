# frozen_string_literal: true

require_relative "test_gui_server"

# How the server holds up against clients that are slow, stalled or too many:
# none of them may tie up a worker, lock out the browser, or keep the server
# from stopping. The timeouts are shrunk so each case takes well under a
# second.
module SlowClientHelpers
  # Sends +text+ one byte every +interval+ seconds on each socket, from a
  # thread of its own, until it runs out or the server hangs up.
  def drip(sockets, text, interval)
    Thread.new do
      text.each_char do |byte|
        sockets.each { |socket| socket.write(byte) }
        sleep interval
      end
    rescue IOError, SystemCallError
      nil
    end
  end

  # A client with a tiny receive window, so the server's writes back up as soon
  # as it stops reading.
  def connect_slow_reader
    socket = track(Socket.new(:INET, :STREAM))
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
    socket.connect(Socket.sockaddr_in(@server.port, FileOrganizer::Gui::Server::HOST))
    socket
  end

  # Reads until the server hangs up; returns how many bytes came.
  def drain(socket)
    total = 0
    loop { total += socket.readpartial(64 * 1024).bytesize }
  rescue EOFError, Errno::ECONNRESET
    total
  end

  # Sparse, so 64 MiB costs no disk.
  def huge_file(size)
    path("huge.bin").tap { |file| File.open(file, "wb") { |io| io.truncate(size) } }
  end
end

class TestGuiServerSlowSenders < Minitest::Test
  include ServerHarness
  include SlowClientHelpers

  # Regression: a worker waited 15 s for each next chunk of a request, so a
  # handful of clients sending a byte now and then held every worker for
  # hours — without needing the session key, which is checked only once a
  # request is whole.
  def test_clients_sending_a_byte_at_a_time_do_not_delay_anyone_else
    drippers = Array.new(Gui::Server::WORKERS + 2) { connect }
    feeder = drip(drippers, "GET /drip HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pad: #{"a" * 100}", 0.2)
    sleep 0.3 # every dripper has begun its request

    3.times do |index|
      started = now
      reply, = exchange(request("GET", "/fast-#{index}"))

      assert_equal "GET /fast-#{index}\n", reply.body
      assert_operator now - started, :<, 0.5, "a normal request waited behind drip-fed ones"
    end
  ensure
    feeder&.kill&.join
  end

  def test_a_request_that_arrives_slowly_but_in_time_is_answered
    socket = connect
    drip([socket], request("GET", "/slowly"), 0.005).join

    reply = read_reply(socket)
    assert_equal "GET /slowly\n", reply.body
    assert_equal "keep-alive", reply.headers["connection"]
    socket.write(request("GET", "/then-quickly"))
    assert_equal "GET /then-quickly\n", read_reply(socket).body
  end
end

class TestGuiServerDeadlines < Minitest::Test
  include ServerHarness
  include SlowClientHelpers

  READ_TIMEOUT = 0.5
  WRITE_TIMEOUT = 0.3
  KEEP_ALIVE = 0.5

  def server_options
    { read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT, keep_alive: KEEP_ALIVE }
  end

  # The deadline runs from the request's first byte: steady progress does not
  # extend it.
  def test_a_request_still_arriving_at_the_read_timeout_gets_408_and_is_closed
    socket = connect
    started = now
    feeder = drip([socket], "GET /late HTTP/1.1\r\nX-Pad: #{"a" * 200}", 0.05)
    reply = read_reply(socket)
    elapsed = now - started

    assert_equal 408, reply.status
    assert_equal "Request Timeout", reply.reason
    assert_equal "close", reply.headers["connection"]
    assert_operator elapsed, :>=, READ_TIMEOUT - 0.05
    assert_operator elapsed, :<, READ_TIMEOUT + 1
    assert closed_by_server?(socket)
    assert @app.requests.empty?
  ensure
    feeder&.kill&.join
  end

  def test_a_connection_left_idle_is_closed_without_a_word
    reply, socket = exchange(request)
    assert_equal 200, reply.status
    started = now

    assert closed_by_server?(socket)
    assert_operator now - started, :>=, KEEP_ALIVE - 0.1
  end

  # Some clients follow a body with a CRLF; that is not the start of a request
  # that then fails to arrive, so it gets no 408.
  def test_a_stray_blank_line_after_a_request_leaves_the_connection_idle
    socket = connect
    socket.write(request("POST", "/form", body: "a=1") + "\r\n")
    assert_equal "POST /form\n", read_reply(socket).body

    assert closed_by_server?(socket), "the idle connection was answered instead of closed quietly"
  end

  # Regression: writes had no deadline, so a client that stopped reading a
  # long response — a paused video — kept its worker for good, and as many
  # such clients as there are workers froze the page.
  def test_clients_that_stop_reading_a_stream_are_dropped_and_free_their_workers
    size = 64 * 1024 * 1024
    serve_file(huge_file(size), offset: 0, length: size, total: size)
    stalled = Array.new(Gui::Server::WORKERS) do
      connect_slow_reader.tap { |socket| socket.write(request("GET", "/media")) }
    end
    wait_until("every worker is streaming") { @app.requests.size == Gui::Server::WORKERS }

    started = now
    reply, = exchange(request("GET", "/other"))
    assert_equal "next\n", reply.body
    assert_operator now - started, :<, WRITE_TIMEOUT + 1.5

    sleep WRITE_TIMEOUT + 0.3 # every stalled stream has passed its deadline
    stalled.each do |socket|
      assert_operator drain(socket), :<, size, "a client that stopped reading kept its connection"
    end
  end

  def test_pipelined_requests_whose_answers_are_never_read_are_dropped
    body = "z" * (256 * 1024)
    respond { |request| Gui::Response.text(request.path == "/big" ? body : "fine") }
    socket = connect_slow_reader
    count = 64
    socket.write(Array.new(count) { request("GET", "/big") }.join)
    wait_until("the server is answering") { !@app.requests.empty? }

    assert_equal "fine\n", exchange(request("GET", "/other")).first.body
    sleep WRITE_TIMEOUT + 0.5
    assert_operator drain(socket), :<, count * body.bytesize
  end
end

class TestGuiServerConnectionLimit < Minitest::Test
  include ServerHarness

  LIMIT = 4

  def server_options
    { max_connections: LIMIT }
  end

  # Regression: only idle sockets were counted, and at the limit newcomers
  # were refused — so a browser's idle connections could lock the page out.
  def test_at_the_limit_the_connection_idle_longest_makes_way
    idle = Array.new(LIMIT) do |index|
      reply, socket = exchange(request("GET", "/idle-#{index}"))
      assert_equal 200, reply.status
      sleep 0.02 # so each has been idle a different length of time
      socket
    end

    assert_equal "GET /new\n", exchange(request("GET", "/new")).first.body
    assert closed_by_server?(idle.first), "the connection idle longest should have made way"
    idle.drop(1).each_with_index do |socket, index|
      socket.write(request("GET", "/again-#{index}"))
      assert_equal "GET /again-#{index}\n", read_reply(socket).body
    end
  end

  def test_at_the_limit_with_no_connection_idle_the_newcomer_is_refused
    busy = Array.new(LIMIT) do |index|
      connect.tap { |socket| socket.write("GET /busy-#{index} HTTP/1.1\r\n") }
    end
    sleep 0.2 # the server has taken in each partial request

    assert closed_by_server?(connect), "a newcomer was let in past the limit"
    busy.each_with_index do |socket, index|
      socket.write("\r\n")
      assert_equal "GET /busy-#{index}\n", read_reply(socket).body
    end
  end
end

class TestGuiServerAcceptBackoff < Minitest::Test
  include ServerHarness

  # Regression: out of descriptors, accept fails but the connection stays
  # queued, the listener stays readable, and the event loop spun a core.
  def test_running_out_of_descriptors_backs_off_instead_of_spinning
    listener = @server.instance_variable_get(:@listener)
    attempts = 0
    listener.define_singleton_method(:accept_nonblock) do |*|
      attempts += 1
      raise Errno::EMFILE
    end
    socket = connect
    sleep 0.5

    assert_operator attempts, :>=, 1
    assert_operator attempts, :<=, 10, "accept was retried #{attempts} times in 0.5 s"
    listener.singleton_class.remove_method(:accept_nonblock)
    socket.write(request("GET", "/after"))
    assert_equal "GET /after\n", read_reply(socket).body
  end

  # Regression: out of descriptors short of the connection limit, accept only
  # backed off, so idle connections kept the page out until they timed out.
  def test_running_out_of_descriptors_makes_the_connection_idle_longest_make_way
    idle = Array.new(2) do |index|
      reply, socket = exchange(request("GET", "/idle-#{index}"))
      assert_equal 200, reply.status
      sleep 0.02 # so each has been idle a different length of time
      socket
    end
    # One descriptor short, once: the next accept is the real one.
    listener = @server.instance_variable_get(:@listener)
    listener.define_singleton_method(:accept_nonblock) do |*|
      singleton_class.remove_method(:accept_nonblock)
      raise Errno::EMFILE
    end

    assert_equal "GET /new\n", exchange(request("GET", "/new")).first.body
    assert idle.first.wait_readable(1) && closed_by_server?(idle.first),
           "the connection idle longest should have made way"
    idle.last.write(request("GET", "/again"))
    assert_equal "GET /again\n", read_reply(idle.last).body
  end
end

class TestGuiServerShutdown < Minitest::Test
  include ServerHarness
  include SlowClientHelpers

  SHUTDOWN = 0.5

  def server_options
    { shutdown_timeout: SHUTDOWN }
  end

  # Regression: each busy worker was given 2 s in turn, so with all of them
  # busy Ctrl-C took 12 s to return.
  def test_stop_gives_busy_workers_one_deadline_between_them
    gate = Queue.new
    respond do
      gate.pop
      Gui::Response.text("too late")
    end
    clients = Array.new(Gui::Server::WORKERS) do |index|
      connect.tap { |socket| socket.write(request("GET", "/slow-#{index}")) }
    end
    wait_until("every worker is busy") { @app.requests.size == Gui::Server::WORKERS }

    started = now
    @server.stop
    assert @thread.join(5), "run did not return after stop"
    elapsed = now - started

    assert_operator elapsed, :>=, SHUTDOWN - 0.05
    assert_operator elapsed, :<, SHUTDOWN + 1
    clients.each { |socket| assert closed_by_server?(socket) }
  ensure
    Gui::Server::WORKERS.times { gate << true } # let the workers finish
  end

  # The write timeout is the default 30 s here: it is closing the socket at
  # the shutdown deadline that frees the worker (the teardown checks that no
  # thread outlives the test).
  def test_stop_does_not_wait_on_a_client_that_stopped_reading
    size = 64 * 1024 * 1024
    serve_file(huge_file(size), offset: 0, length: size, total: size)
    stalled = connect_slow_reader
    stalled.write(request("GET", "/media"))
    wait_until("the stream has begun") { !@app.requests.empty? }

    started = now
    @server.stop
    assert @thread.join(5), "run did not return after stop"
    assert_operator now - started, :<, SHUTDOWN + 1
    assert_operator drain(stalled), :<, size
  end

  def test_stop_lets_a_request_already_being_answered_finish
    respond do
      sleep 0.1
      Gui::Response.text("done")
    end
    socket = connect
    socket.write(request("GET", "/almost"))
    wait_until("the request is being answered") { !@app.requests.empty? }
    @server.stop

    reply = read_reply(socket)
    assert_equal "done\n", reply.body
    assert_equal "close", reply.headers["connection"]
    assert @thread.join(5), "run did not return after stop"
  end

  def test_an_interrupt_stops_the_server_cleanly
    reply, socket = exchange(request)
    assert_equal 200, reply.status

    @thread.raise(Interrupt)
    assert @thread.join(5), "run did not return after an interrupt"
    assert_equal :interrupted, @thread.value
    assert closed_by_server?(socket)
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new(Gui::Server::HOST, @server.port).close }
  end
end

# The server in a process of its own, under a low descriptor limit such as the
# 256 a macOS shell starts with.
class TestGuiServerDescriptorLimit < Minitest::Test
  LIMIT = 128
  LIB = File.expand_path("../lib/file_organizer", __dir__)
  MEDIA = File.expand_path("../lib/file_organizer/gui.rb", __dir__)

  # Streams MEDIA for /media and echoes anything else; stops when the test
  # closes its standard input.
  SERVER = <<~RUBY
    require #{LIB.dump}
    require #{"#{LIB}/gui".dump}
    server = FileOrganizer::Gui::Server.new(port: 0).start
    $stdout.puts(server.port)
    $stdout.flush
    Thread.new { $stdin.read; server.stop }
    server.run(lambda do |request|
      next FileOrganizer::Gui::Response.text(request.target) unless request.path == "/media"

      size = File.size(#{MEDIA.dump})
      FileOrganizer::Gui::Response.file(#{MEDIA.dump}, content_type: "text/plain", offset: 0, length: size, total: size)
    end)
  RUBY

  # Regression: the connection limit (256) was above what the process could
  # open, so accept ran out of descriptors before any idle connection was
  # asked to make way, and a client holding a few hundred idle sockets — no
  # key needed — locked the page out. Out of descriptors, the workers could
  # not open the files they were asked to stream either.
  def test_idle_connections_cannot_use_up_a_low_descriptor_limit
    skip "no descriptor limit on this platform" unless defined?(Process::RLIMIT_NOFILE)

    sockets = []
    IO.popen([RbConfig.ruby, "-e", SERVER], "r+", rlimit_nofile: [LIMIT, LIMIT]) do |server|
      port = Integer(server.gets)
      (LIMIT + 32).times { sockets << TCPSocket.new(FileOrganizer::Gui::Server::HOST, port) }
      sockets << (browser = TCPSocket.new(FileOrganizer::Gui::Server::HOST, port))

      browser.write(get("/page", port))
      assert browser.wait_readable(3), "idle connections locked the page out"
      assert_equal ["200", "/page\n"], reply(browser)
      browser.write(get("/media", port))
      assert_equal ["200", File.binread(MEDIA)], reply(browser), "no descriptor was left to open the file"
    ensure
      sockets.each(&:close)
      server.close_write
    end
    assert_predicate $?, :success?
  end

  private

  def get(target, port)
    "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
  end

  # [status, body] of one response.
  def reply(socket)
    head = socket.gets("\r\n\r\n")
    [head[%r{\AHTTP/1\.1 (\d+)}, 1], socket.read(Integer(head[/^Content-Length: (\d+)/i, 1]))]
  end
end
