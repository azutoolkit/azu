require "../spec_helper"
require "http/client"
require "http/web_socket"

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
end
