require "../spec_helper"
require "http/client"
require "http/web_socket"
require "openssl"
require "file_utils"
require "log/spec"

private class Echo < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
    send "echo #{message}"
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

private struct BodyLength
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    body = context.request.body.try(&.gets_to_end) || ""
    context.response << "body #{body.bytesize}"
    context
  end
end

private struct Hello
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "hello"
    context
  end
end

private def limited_app(**options) : Azu::App
  app = Azu::App.new
  limits = app.config.limits
  limits.header_timeout = (options[:header]? || 0.6).seconds
  limits.read_timeout = (options[:read]? || 0.6).seconds
  limits.write_timeout = (options[:write]? || 5.0).seconds
  limits.keep_alive_timeout = (options[:keep_alive]? || 0.8).seconds
  limits.min_body_rate = options[:rate]? || 1024
  limits.max_connections = options[:max]? || 100
  app.config.websocket.ping_interval = nil
  app.routes do
    get "/", Hello
    post "/body", BodyLength
    ws "/echo", Echo
  end
  app
end

private def with_limited_server(app : Azu::App, &)
  server = app.server
  address = Azu::ServerLimits.bind_tcp(server, app.config.limits, "127.0.0.1", 0, false)
  spawn { server.listen }
  200.times do
    TCPSocket.new(address.address, address.port).close
    break
  rescue Socket::ConnectError
    sleep 10.milliseconds
  end
  begin
    yield address
  ensure
    server.close
  end
end

# Everything the server sends until it closes the connection or *within* passes; {text, closed, seconds taken}.
private def read_all(socket : TCPSocket, within : Time::Span = 5.seconds) : {String, Bool, Float64}
  started = Time.instant
  socket.read_timeout = within
  io = IO::Memory.new
  closed = begin
    buffer = Bytes.new(4096)
    loop do
      count = socket.read(buffer)
      break true if count == 0
      io.write(buffer[0, count])
    end
  rescue IO::TimeoutError
    false
  rescue IO::Error
    true
  end
  {io.to_s, closed, (Time.instant - started).total_seconds}
end

private def with_env(name : String, value : String, &)
  previous = ENV[name]?
  ENV[name] = value
  yield
ensure
  previous ? (ENV[name] = previous) : ENV.delete(name)
end

describe "server limits" do
  it "answers requests as before" do
    with_limited_server(limited_app) do |address|
      client = HTTP::Client.new(address.address, address.port)
      client.get("/").body.should eq "hello"
      client.post("/body", body: "abc").body.should eq "body 3"
      client.get("/").body.should eq "hello" # on the same kept-alive connection
    end
  end

  describe "headers" do
    it "cuts a client that sends them a byte at a time, however often it sends" do
      with_limited_server(limited_app(header: 0.6)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        started = Time.instant
        spawn do
          "GET / HTTP/1.1\r\nHost: x\r\nX-Slow: #{"a" * 200}".each_char do |char|
            socket << char
            socket.flush
            sleep 0.1.seconds
          end
        rescue IO::Error
        end
        text, closed, seconds = read_all(socket)
        closed.should be_true
        text.should start_with("HTTP/1.1 408")
        seconds.should be < 2.0
        (Time.instant - started).should be < 3.seconds
      end
    end

    it "closes a connection that never sends anything" do
      with_limited_server(limited_app(header: 0.5)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        text, closed, seconds = read_all(socket)
        {closed, text}.should eq({true, ""})
        seconds.should be < 2.0
      end
    end

    it "lets a request through whose headers arrive in two pieces within the limit" do
      with_limited_server(limited_app(header: 0.8)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n"
        socket.flush
        sleep 0.3.seconds
        socket << "Connection: close\r\n\r\n"
        socket.flush
        text, _, _ = read_all(socket)
        text.should contain("hello")
      end
    end

    it "starts the header clock again for each request of a kept-alive connection" do
      with_limited_server(limited_app(header: 0.7, keep_alive: 3.0)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        socket.flush
        socket.read_timeout = 2.seconds
        socket.gets.to_s.should start_with("HTTP/1.1 200")
        loop { break if socket.gets.to_s.strip.empty? }
        socket.read(Bytes.new(5))
        sleep 0.5.seconds # idle, within keep-alive
        socket << "GET / HTTP/1.1\r\nHost: x\r\n"
        socket.flush
        sleep 0.4.seconds # 0.9 s since the connection opened, 0.4 s since this request began
        socket << "Connection: close\r\n\r\n"
        socket.flush
        text = socket.gets_to_end
        text.should start_with("HTTP/1.1 200")
        text.should contain("hello")
      end
    end
  end

  describe "bodies" do
    it "cuts a body that drips a byte at a time, though every read is within read_timeout" do
      with_limited_server(limited_app(read: 0.8, rate: 1024)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"
        socket.flush
        spawn do
          100.times do
            socket << "a"
            socket.flush
            sleep 0.3.seconds
          end
        rescue IO::Error
        end
        _, closed, seconds = read_all(socket, 8.seconds)
        closed.should be_true
        seconds.should be < 4.0 # the drip would have taken 30 s
      end
    end

    it "cuts a body that stops coming after read_timeout" do
      with_limited_server(limited_app(read: 0.5)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nab"
        socket.flush
        _, closed, seconds = read_all(socket, 8.seconds)
        closed.should be_true
        seconds.should be < 3.0
      end
    end

    it "takes a body that arrives at a reasonable pace, even if it takes longer than read_timeout in all" do
      with_limited_server(limited_app(read: 0.5, rate: 1024)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 40000\r\nConnection: close\r\n\r\n"
        socket.flush
        20.times do
          socket << "z" * 2000
          socket.flush
          sleep 0.1.seconds
        end
        text, _, _ = read_all(socket)
        text.should contain("body 40000")
      end
    end
  end

  describe "keep-alive" do
    it "closes a connection that waits too long for its next request, and serves one that does not" do
      with_limited_server(limited_app(keep_alive: 0.6, read: 4.0)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        socket.flush
        socket.read_timeout = 2.seconds
        socket.gets.to_s.should start_with("HTTP/1.1 200")
        loop { break if socket.gets.to_s.strip.empty? } # the rest of the headers
        socket.read(Bytes.new(5))
        started = Time.instant
        socket.read_timeout = 5.seconds
        socket.read(Bytes.new(1)).should eq 0 # the server closed
        (Time.instant - started).should be < 2.5.seconds
      end
    end
  end

  describe "connections" do
    it "turns the one over max_connections away with 503, and takes the next when a place is free" do
      with_limited_server(limited_app(max: 2, header: 30.0)) do |address|
        sleep 0.3.seconds # the readiness probe of with_limited_server gives its place back when the server sees it close
        held = [TCPSocket.new(address.address, address.port), TCPSocket.new(address.address, address.port)]
        sleep 0.2.seconds # let the server accept both
        extra = TCPSocket.new(address.address, address.port)
        text, closed, _ = read_all(extra, 3.seconds)
        closed.should be_true
        text.should start_with("HTTP/1.1 503")
        text.should contain("Retry-After: 1")

        held.first.close
        sleep 0.3.seconds
        client = HTTP::Client.new(address.address, address.port)
        client.get("/").body.should eq "hello"
        client.close
        held.each { |socket| socket.close rescue nil }
      end
    end
  end

  describe "WebSockets" do
    it "are not cut by the request limits, however long they idle" do
      app = limited_app(header: 0.4, read: 0.4, keep_alive: 0.4)
      with_limited_server(app) do |address|
        received = ::Channel(String).new(4)
        socket = HTTP::WebSocket.new(address.address, "/echo", address.port)
        socket.on_message { |message| received.send(message) }
        spawn { socket.run }
        sleep 1.8.seconds # more than four times every limit
        socket.send "late"
        select
        when message = received.receive
          message.should eq "echo late"
        when timeout(3.seconds)
          fail "the WebSocket was cut"
        end
        socket.close
      end
    end
  end

  describe "App#start" do
    it "serves through the limited listener, and stop still finishes with connections open" do
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.local_address.port
      probe.close
      app = limited_app(header: 0.5)
      app.config.host = "127.0.0.1"
      app.config.port = port
      spawn { app.start(signals: false, teardown: false) }
      wait_until(5.seconds) { (TCPSocket.new("127.0.0.1", port).close; true) rescue false }.should be_true

      silent = TCPSocket.new("127.0.0.1", port)
      text, closed, seconds = read_all(silent)
      {closed, text}.should eq({true, ""}) # cut by header_timeout: the listener App#start bound is the limited one
      seconds.should be < 3.0

      idle = TCPSocket.new("127.0.0.1", port) # still open when the app stops
      HTTP::Client.new("127.0.0.1", port).get("/").body.should eq "hello"
      app.stop(3.seconds).should be_true
      idle.close
    end
  end

  describe "Expect: 100-continue" do
    it "keeps timing the upload as a body, not as the headers of a new request" do
      with_limited_server(limited_app(header: 0.6, read: 1.0, keep_alive: 0.8)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 40000\r\n\r\n"
        socket.flush
        socket.read_timeout = 3.seconds
        socket.gets.to_s.should start_with("HTTP/1.1 100 Continue")
        socket.gets
        started = Time.instant
        20.times do # 40 KB over about 1.6 s: longer than header_timeout, well above min_body_rate
          socket << "z" * 2000
          socket.flush
          sleep 0.08.seconds
        end
        (Time.instant - started).should be > 0.6.seconds
        socket.gets.to_s.should start_with("HTTP/1.1 200")
        loop { break if socket.gets.to_s.strip.empty? }
        buffer = Bytes.new(10)
        socket.read(buffer)
        String.new(buffer).should eq "body 40000"

        socket << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" # the same connection, a second request
        socket.flush
        socket.gets_to_end.should contain("hello")
      end
    end

    it "does not write an unsolicited 408 to the idle connection afterwards" do
      with_limited_server(limited_app(header: 0.6, read: 1.0, keep_alive: 0.8)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n"
        socket.flush
        socket.read_timeout = 3.seconds
        socket.gets
        socket.gets
        socket << "0123456789"
        socket.flush
        text, closed, _ = read_all(socket, 4.seconds)
        closed.should be_true
        text.should contain("body 10")
        text.should_not contain("408")
      end
    end
  end

  describe "the configuration" do
    it "reads seconds, treats 0 and less as no limit, and keeps the default for what is not a number" do
      with_env("SERVER_HEADER_TIMEOUT", "2.5") { Azu::ServerLimitsConfiguration.seconds("SERVER_HEADER_TIMEOUT", 10).should eq 2.5.seconds }
      ["0", "-1", "-0.5"].each do |value|
        with_env("SERVER_HEADER_TIMEOUT", value) { Azu::ServerLimitsConfiguration.seconds("SERVER_HEADER_TIMEOUT", 10).should be_nil }
      end
      ["", "  "].each do |value|
        with_env("SERVER_HEADER_TIMEOUT", value) { Azu::ServerLimitsConfiguration.seconds("SERVER_HEADER_TIMEOUT", 10).should eq 10.seconds }
      end
      ["abc", "inf", "-inf", "nan", "1e30", "99999999999"].each do |value|
        Log.capture("Azu::ServerLimits") do |logs|
          with_env("SERVER_HEADER_TIMEOUT", value) { Azu::ServerLimitsConfiguration.seconds("SERVER_HEADER_TIMEOUT", 10).should eq 10.seconds }
          logs.next(:warn, /SERVER_HEADER_TIMEOUT/)
        end
      end
      Azu::ServerLimitsConfiguration.seconds("SERVER_NOT_SET_ANYWHERE", 7).should eq 7.seconds
    end

    it "reads integers, and keeps the default for what is not one" do
      with_env("SERVER_MAX_CONNECTIONS", "12") { Azu::ServerLimitsConfiguration.integer("SERVER_MAX_CONNECTIONS", 5).should eq 12 }
      with_env("SERVER_MAX_CONNECTIONS", "") { Azu::ServerLimitsConfiguration.integer("SERVER_MAX_CONNECTIONS", 5).should eq 5 }
      Log.capture("Azu::ServerLimits") do |logs|
        with_env("SERVER_MAX_CONNECTIONS", "many") { Azu::ServerLimitsConfiguration.integer("SERVER_MAX_CONNECTIONS", 5).should eq 5 }
        logs.next(:warn, /SERVER_MAX_CONNECTIONS/)
      end
    end

    it "keeps the default connection cap below the open-file limit" do
      LibC.getrlimit(LibC::RLIMIT_NOFILE, out limit)
      cap = Azu::ServerLimitsConfiguration.default_max_connections
      cap.should be <= 10_000
      cap.should be < limit.rlim_cur if limit.rlim_cur < 1_000_000
    end

    it "does no waiting at all when every timeout is off" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.header_timeout = nil
      limits.read_timeout = nil
      limits.keep_alive_timeout = nil
      clock = Azu::RequestClock.new(limits)
      clock.before_read.should be_nil
      clock.after_read("GET / HTTP/1.1\r\n\r\n".to_slice)
      clock.phase.body?.should be_true
      clock.before_read.should be_nil
    end

    it "caps what a fast start buys toward the body's deadline" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.read_timeout = 2.seconds
      limits.min_body_rate = 1024
      clock = Azu::RequestClock.new(limits)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".to_slice)
      clock.after_read(Bytes.new(50_000_000)) # at 1 KB/s that would earn 13 hours
      deadline = clock.body_deadline.not_nil!
      (deadline - Time.instant).should be < 23.seconds # 2 s of grace and at most 10 x 2 s of credit
    end

    it "does not take 100 Continue for the response" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".to_slice)
      clock.after_write("HTTP/1.1 100 Continue\r\n\r\n".to_slice)
      clock.before_read
      clock.phase.body?.should be_true
      clock.after_write("HTTP/1.1 200 OK\r\n".to_slice)
      clock.before_read
      clock.phase.idle?.should be_true
    end
  end

  describe "a slow request body" do
    it "is a quiet 408 through Rescuer: one line, no backtrace" do
      app = limited_app(read: 0.4)
      backend = ::Log::MemoryBackend.new
      log = ::Log.new("slow_body_spec", backend, :debug)
      server = app.server([Azu::Handler::Rescuer.new(log)] of HTTP::Handler)
      address = Azu::ServerLimits.bind_tcp(server, app.config.limits, "127.0.0.1", 0, false)
      spawn { server.listen }
      begin
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nab"
        socket.flush
        text, closed, _ = read_all(socket, 5.seconds)
        closed.should be_true
        text.should start_with("HTTP/1.1 408")
        messages = backend.entries.map(&.message)
        messages.any?(&.includes?("-> 408")).should be_true
        messages.none?(&.includes?("Error Processing Request")).should be_true
        backend.entries.none?(&.exception).should be_true
      ensure
        server.close
      end
    end
  end

  describe "TLS" do
    dir = Path[Dir.tempdir, "azu_server_limits_tls"].to_s

    tls_server = ->(app : Azu::App) {
      Dir.mkdir_p(dir)
      key = "#{dir}/key.pem"
      cert = "#{dir}/cert.pem"
      unless File.exists?(cert)
        Process.run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = cert
      context.private_key = key
      server = app.server
      address = Azu.bind_tls(server, "127.0.0.1", 0, context, false, false, app.config.limits)
      spawn { server.listen }
      {server, address}
    }

    client_context = OpenSSL::SSL::Context::Client.new
    client_context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

    it "keeps a WebSocket open however long it idles, and serves requests" do
      server, address = tls_server.call(limited_app(header: 0.4, read: 0.4, keep_alive: 0.4))
      begin
        HTTP::Client.new(address.address, address.port, tls: client_context).get("/").body.should eq "hello"

        received = ::Channel(String).new(4)
        socket = HTTP::WebSocket.new("127.0.0.1", "/echo", address.port, tls: client_context)
        socket.on_message { |message| received.send(message) }
        spawn { socket.run }
        sleep 1.8.seconds
        socket.send "late"
        select
        when message = received.receive
          message.should eq "echo late"
        when timeout(3.seconds)
          fail "the TLS WebSocket was cut"
        end
        socket.close
      ensure
        server.close
      end
    end

    it "cuts a client that drips the handshake or the headers, with the header deadline" do
      server, address = tls_server.call(limited_app(header: 0.6, read: 5.0))
      begin
        socket = TCPSocket.new(address.address, address.port)
        spawn do
          100.times do
            socket << "\x16" # a TLS record that never completes
            socket.flush
            sleep 0.2.seconds
          end
        rescue IO::Error
        end
        _, closed, seconds = read_all(socket, 8.seconds)
        closed.should be_true
        seconds.should be < 3.0
      ensure
        server.close
      end
    end

    it "closes an idle kept-alive TLS connection after keep_alive_timeout" do
      server, address = tls_server.call(limited_app(keep_alive: 0.5, read: 4.0))
      begin
        socket = OpenSSL::SSL::Socket::Client.new(TCPSocket.new(address.address, address.port), client_context, hostname: "localhost")
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        socket.flush
        socket.read_timeout = 3.seconds if socket.responds_to?(:read_timeout=)
        socket.gets.to_s.should start_with("HTTP/1.1 200")
        loop { break if socket.gets.to_s.strip.empty? }
        socket.read(Bytes.new(5))
        started = Time.instant
        (socket.read(Bytes.new(1)) rescue 0).should eq 0
        (Time.instant - started).should be < 2.5.seconds
      ensure
        server.close
      end
    end
  end
end
