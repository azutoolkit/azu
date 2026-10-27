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

# Busy (a slow query, a lock) before it reads the body the client sent at once.
private struct BusyThenBody
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    sleep 1.5.seconds
    body = context.request.body.try(&.gets_to_end) || ""
    context.response << "body #{body.bytesize}"
    context
  end
end

# A timeout that is not the client's: an upstream HTTP::Client, Redis or database socket.
private struct UpstreamTimeout
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    raise IO::TimeoutError.new("Read timed out")
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
    post "/busy", BusyThenBody
    get "/upstream", UpstreamTimeout
    ws "/echo", Echo
  end
  app
end

private def with_limited_server(app : Azu::App, handlers = [] of HTTP::Handler, &)
  server = app.server(handlers)
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

# The same app with none of the limits: what Crystal's own server answers, the reference for the limited one.
private def with_plain_server(app : Azu::App, &)
  server = app.server
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield address
  ensure
    server.close
  end
end

# Sends *text* in pieces of *sizes* (cycled; nil: one write) and reads everything until the server closes.
private def exchange(address : Socket::IPAddress, text : String, sizes : Array(Int32)? = nil) : {String, Bool, Float64}
  socket = TCPSocket.new(address.address, address.port)
  socket.tcp_nodelay = true
  started = Time.instant
  bytes = text.to_slice
  offset = 0
  piece = 0
  begin
    while offset < bytes.size
      size = Math.min(sizes.try(&.[piece % sizes.size]) || bytes.size, bytes.size - offset)
      socket.write(bytes[offset, size])
      socket.flush
      offset += size
      piece += 1
    end
  rescue IO::Error
    # The server answered and closed before the client was done writing (a request it refuses): read the answer.
  end
  text, closed, _ = read_all(socket, 4.seconds)
  # An error page carries its own id and time.
  text = text.gsub(/\b[0-9a-f]{32}\b/, "ID").gsub(/Timestamp: \S+/, "Timestamp")
  {text, closed, (Time.instant - started).total_seconds}
rescue ex : IO::Error
  {"(#{ex.class}: #{ex.message})", true, 0.0}
ensure
  socket.try &.close
end

private def pipelined(post_lines : String, body : String) : String
  "GET / HTTP/1.1\r\nHost: x\r\n\r\n" \
  "POST /body HTTP/1.1\r\nHost: x\r\n#{post_lines}\r\n\r\n#{body}" \
  "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
end

CHUNKED = "5\r\nhello\r\n0\r\n\r\n"

TLS_DIR = Path[Dir.tempdir, "azu_server_limits_tls"].to_s

private def tls_server_context : OpenSSL::SSL::Context::Server
  Dir.mkdir_p(TLS_DIR)
  key = "#{TLS_DIR}/key.pem"
  cert = "#{TLS_DIR}/cert.pem"
  unless File.exists?(cert)
    Process.run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"], output: Process::Redirect::Close, error: Process::Redirect::Close)
  end
  context = OpenSSL::SSL::Context::Server.new
  context.certificate_chain = cert
  context.private_key = key
  context
end

# The limited server over plain HTTP, or over TLS when *tls*.
private def with_server(app : Azu::App, tls : Bool, handlers = [] of HTTP::Handler, &)
  return with_limited_server(app, handlers) { |address| yield address } unless tls
  server = app.server(handlers)
  address = Azu.bind_tls(server, "127.0.0.1", 0, tls_server_context, false, false, app.config.limits)
  spawn { server.listen }
  begin
    yield address
  ensure
    server.close
  end
end

# A connection to *address*, over TLS when *tls*: {what to talk on, the TCP socket under it}. Every write is sent at once
# (under TLS, as a record of its own).
private def connect(address : Socket::IPAddress, tls : Bool) : {IO, TCPSocket}
  tcp = TCPSocket.new(address.address, address.port)
  tcp.tcp_nodelay = true
  return {tcp, tcp} unless tls
  context = OpenSSL::SSL::Context::Client.new
  context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  socket = OpenSSL::SSL::Socket::Client.new(tcp, context, hostname: "localhost")
  socket.sync = true
  {socket, tcp}
end

# Everything the server sends on *io* until it closes the connection or *within* passes; {text, seconds taken}.
private def read_until_close(io : IO, tcp : TCPSocket, within : Time::Span = 6.seconds) : {String, Float64}
  started = Time.instant
  tcp.read_timeout = within
  text = IO::Memory.new
  buffer = Bytes.new(4096)
  begin
    while (count = io.read(buffer)) > 0
      text.write(buffer[0, count])
    end
  rescue IO::Error | OpenSSL::Error
  end
  {text.to_s, (Time.instant - started).total_seconds}
end

private def statuses(text : String) : Array(String)
  text.scan(/HTTP\/1.1 \d+/).map(&.[0])
end

private def quiet_rescuer : Array(HTTP::Handler)
  [Azu::Handler::Rescuer.new(::Log.new("server_limits_spec", ::Log::MemoryBackend.new, :debug))] of HTTP::Handler
end

# Whether a `drip_proxy` drips (a reference: an `Atomic` is a struct, and a copy of it would not switch the proxy).
private class DripSwitch
  @on = Atomic(Bool).new(false)

  def on? : Bool
    @on.get
  end

  def turn_on : Nil
    @on.set(true)
  end
end

# Forwards what a client sends to *target*; once switched on, *burst* bytes at once, then *per* bytes every *period*.
# {proxy, switch}
private def drip_proxy(target : Socket::IPAddress, per : Int32, period : Time::Span, burst : Int32 = 0) : {TCPServer, DripSwitch}
  drip = DripSwitch.new
  proxy = TCPServer.new("127.0.0.1", 0)
  spawn do
    client = proxy.accept? || next
    upstream = TCPSocket.new(target.address, target.port)
    upstream.tcp_nodelay = true
    spawn do
      IO.copy(upstream, client) rescue nil
      client.close rescue nil
    end
    buffer = Bytes.new(65_536)
    loop do
      count = client.read(buffer)
      break if count == 0
      offset = 0
      while offset < count
        size = drip.on? ? Math.min(burst > 0 ? burst : per, count - offset) : count - offset
        burst -= size if drip.on? && burst > 0
        upstream.write(buffer[offset, size])
        upstream.flush
        offset += size
        sleep period if drip.on?
      end
    end
  rescue IO::Error
  ensure
    upstream.try { |socket| socket.close rescue nil }
  end
  {proxy, drip}
end

# Content-Length and Transfer-Encoding as clients may spell them, well or badly: {header lines, body}. A value that is
# not a number (`-5`, `5x`, two that differ) makes Crystal's server raise and drop the connection, printing the error:
# those are in the RequestStream corpus (spec/azu/request_stream_spec.cr) instead.
FRAMINGS = [
  {"Content-Length: 5", "hello"}, {"content-length: 5", "hello"}, {"CONTENT-LENGTH: 5", "hello"},
  {"Content_Length: 5", "hello"}, {"content_length: 5", "hello"}, {"Content-Length:5", "hello"},
  {"Content-Length: \t5", "hello"}, {"Content-Length: 5 ", "hello"}, {"Content-Length: 05", "hello"},
  {"Content-Length: #{" " * 80}5", "hello"}, {"X-Pad: #{"a" * 300}\r\nContent_Length: 5", "hello"},
  {"Content-Length: 5\r\nContent-Length: 5", "hello"}, {"Content-Length: 5\r\nContent_Length: 5", "hello"},
  {"Content-Length : 5", "hello"},
  {"X-A: b\r\n folded\r\nContent-Length: 5", "hello"}, {"X-A: b\r\n\tfolded", ""},
  {"Content-Length: 6", "hello"}, {"Content-Length: 4", "hello"},
  {"Transfer-Encoding: chunked", CHUNKED}, {"transfer_encoding: chunked", CHUNKED},
  {"Transfer_Encoding: chunked", CHUNKED}, {"Transfer-Encoding: Chunked", CHUNKED},
  {"Transfer-Encoding: gzip, chunked", CHUNKED}, {"Transfer-Encoding: chunked\r\nContent-Length: 5", CHUNKED},
  {"Transfer_Encoding: chunked\r\nContent_Length: 5", CHUNKED}, {"Content_Length: 5\r\nTransfer_Encoding: chunked", CHUNKED},
]

# A chunked body with a trailer: the stream does not read trailers, so its end is unknown (see RequestStream).
UNKNOWN_CHUNKED = "5\r\nhello\r\n0\r\nX-Trailer: a\r\n\r\n"
# The headers of a request that come a byte at a time, as they are dripped after the previous request's answer.
SLOW_HEADERS = "GET / HTTP/1.1\r\nHost: x\r\nX-Slow: #{"a" * 40}"

# Writes *text* to *io* in pieces of *per* bytes every *period*, in a fiber of its own, until the server closes.
private def drip(io : IO, text : String, period : Time::Span, per : Int32 = 1) : Nil
  spawn do
    text.each_char.each_slice(per) do |chars|
      io << chars.join
      io.flush
      sleep period
    end
  rescue IO::Error | OpenSSL::Error
  end
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

    it "takes a steady body above min_body_rate however long it takes in all" do
      # 100 KB at about 25 KB/s: four seconds, more than ten times read_timeout, and 25 times min_body_rate.
      with_limited_server(limited_app(read: 0.3, rate: 1024)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n"
        socket.flush
        started = Time.instant
        begin
          40.times do
            socket << "z" * 2500
            socket.flush
            sleep 0.1.seconds
          end
        rescue IO::Error
        end
        (Time.instant - started).should be > 3.5.seconds
        text, _, _ = read_all(socket)
        text.should contain("body 100000")
      end
    end

    it "does not count the time the handler spends before it reads a body that was sent at once" do
      with_limited_server(limited_app(read: 0.5, rate: 262_144)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /busy HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n" << "z" * 100_000
        socket.flush
        text, _, _ = read_all(socket, 8.seconds)
        text.should contain("body 100000")
      end
    end
  end

  describe "pipelining" do
    it "times a request whose headers were sent with the previous one as a body, and answers each request once" do
      with_limited_server(limited_app(header: 0.6, read: 2.0), [Azu::Handler::Rescuer.new] of HTTP::Handler) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 20000\r\n"
        socket.flush
        sleep 0.2.seconds
        socket << "\r\n"
        socket.flush
        begin
          20.times do # 20 KB over about 1.6 s: longer than header_timeout, far above min_body_rate
            socket << "z" * 1000
            socket.flush
            sleep 0.08.seconds
          end
        rescue IO::Error
        end
        text, _, _ = read_all(socket)
        text.scan(/HTTP\/1.1 \d+/).map(&.[0]).should eq ["HTTP/1.1 200", "HTTP/1.1 200"]
        text.should contain("hello")
        text.should contain("body 20000")
      end
    end

    {false, true}.each do |tls|
      transport = tls ? "TLS" : "plain HTTP"

      describe "requests answered from the buffer, with no read between them (#{transport})" do
        it "times the wait after two requests sent in one write as idle (keep_alive_timeout), not as a body" do
          with_server(limited_app(header: 0.6, read: 0.4, keep_alive: 1.5), tls) do |address|
            io, tcp = connect(address, tls)
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"
            io.flush
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq ["HTTP/1.1 200", "HTTP/1.1 200"]
            seconds.should be > 1.2 # read_timeout would have cut it at 0.4 s
            seconds.should be < 3.0
          end
        end

        it "does the same for three" do
          with_server(limited_app(header: 0.6, read: 0.4, keep_alive: 1.5), tls) do |address|
            io, tcp = connect(address, tls)
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\n" * 3
            io.flush
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq ["HTTP/1.1 200"] * 3
            seconds.should be > 1.2
          end
        end

        it "times the next request's headers after them with header_timeout" do
          with_server(limited_app(header: 0.6, read: 3.0, keep_alive: 5.0), tls) do |address|
            io, tcp = connect(address, tls)
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"
            io.flush
            sleep 0.2.seconds
            spawn do
              "GET / HTTP/1.1\r\nHost: x\r\nX-Slow: #{"a" * 40}".each_char do |char|
                io << char
                io.flush
                sleep 0.15.seconds
              end
            rescue IO::Error | OpenSSL::Error
            end
            text, seconds = read_until_close(io, tcp)
            seconds.should be < 1.5 # header_timeout, not read_timeout (3 s)
            # Over plain HTTP the late request is told 408; under TLS the connection is just closed.
            statuses(text).should eq(tls ? ["HTTP/1.1 200"] * 2 : ["HTTP/1.1 200", "HTTP/1.1 200", "HTTP/1.1 408"])
          end
        end

        it "times the body of the last one as a body when it is still coming, and the wait after it as idle" do
          with_server(limited_app(header: 0.6, read: 0.6, keep_alive: 1.5), tls) do |address|
            io, tcp = connect(address, tls)
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc"
            io.flush
            sleep 0.3.seconds
            io << "defghij"
            io.flush
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq ["HTTP/1.1 200", "HTTP/1.1 200"]
            text.should contain("body 10")
            seconds.should be > 1.2
          end
        end

        it "cuts the body of the last one at read_timeout when it stops coming" do
          with_server(limited_app(header: 0.6, read: 0.4, keep_alive: 3.0), tls, quiet_rescuer) do |address|
            io, tcp = connect(address, tls)
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc"
            io.flush
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq ["HTTP/1.1 200", "HTTP/1.1 408"]
            seconds.should be < 1.5 # as a body: not keep_alive_timeout (3 s)
          end
        end

        it "cuts a body of unknown length of the last one at read_timeout when it stops coming" do
          with_server(limited_app(header: 0.6, read: 0.4, keep_alive: 3.0), tls, quiet_rescuer) do |address|
            io, tcp = connect(address, tls)
            # "5 " is a size the stream does not read (Crystal's parser does): the body's end is unknown.
            io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhel"
            io.flush
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq ["HTTP/1.1 200", "HTTP/1.1 408"]
            seconds.should be < 1.5 # as a body: not keep_alive_timeout (3 s)
          end
        end

        {0, 10}.each do |rate|
          it "times the headers of a request after a chunked one answered with the one before it, with header_timeout (min_body_rate #{rate})" do
            with_server(limited_app(header: 0.6, read: 0.6, keep_alive: 5.0, rate: rate), tls) do |address|
              io, tcp = connect(address, tls)
              io << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n#{CHUNKED}"
              io.flush
              sleep 0.2.seconds
              # Every byte within read_timeout, and at or above min_body_rate: only header_timeout cuts it.
              drip(io, SLOW_HEADERS, 0.3.seconds, rate == 0 ? 1 : 3)
              text, seconds = read_until_close(io, tcp, 12.seconds)
              seconds.should be < 1.6
              statuses(text).should eq(tls ? ["HTTP/1.1 200"] * 2 : ["HTTP/1.1 200", "HTTP/1.1 200", "HTTP/1.1 408"])
              text.should contain("body 5")
            end
          end
        end
      end
    end

    it "serves requests sent together in one write" do
      with_limited_server(limited_app) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\nPOST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        socket.flush
        text, _, _ = read_all(socket)
        text.scan(/hello|body \d+/).map(&.[0]).should eq ["hello", "body 3", "hello"]
      end
    end
  end

  describe "framing" do
    it "answers every spelling of Content-Length and Transfer-Encoding as Crystal's server does, without waiting" do
      app = limited_app(header: 1.5, read: 1.5, keep_alive: 3.0)
      with_plain_server(app) do |plain|
        with_limited_server(app) do |limited|
          FRAMINGS.each do |lines, body|
            text = pipelined(lines, body)
            expected, _, _ = exchange(plain, text)
            got, closed, seconds = exchange(limited, text)
            {lines, got}.should eq({lines, expected})
            closed.should be_true
            seconds.should be < 1.2 # every request is answered at once: none waits for a timeout
          end
        end
      end
    end

    it "answers the same however the client slices its writes" do
      app = limited_app(header: 1.5, read: 1.5, keep_alive: 3.0)
      random = Random.new(42)
      with_limited_server(app) do |limited|
        FRAMINGS.each do |lines, body|
          text = pipelined(lines, body)
          whole, _, _ = exchange(limited, text)
          [[1], Array.new(6) { random.rand(1..30) }].each do |sizes|
            sliced = exchange(limited, text, sizes)[0]
            # A request the server refuses is answered and the connection closed while the client may still be
            # writing; the reset that follows can cut the answer short (seen with -Dpreview_mt, stock server too).
            next if whole.includes?("HTTP/1.1 400") && whole.starts_with?(sliced)
            {lines, sizes, sliced}.should eq({lines, sizes, whole})
          end
        end
        [{"Content_Length: 5", "hello"}, {"Transfer_Encoding: chunked", CHUNKED}].each do |lines, body|
          text = pipelined(lines, body)
          whole, _, _ = exchange(limited, text)
          whole.scan(/hello|body \d+/).map(&.[0]).should eq ["hello", "body 5", "hello"]
          (1...text.bytesize).each { |at| {at, exchange(limited, text, [at, text.bytesize])[0]}.should eq({at, whole}) }
        end
      end
    end

    {"Content_Length: 10" => "0123456789", "content_length: 10" => "0123456789",
     "Transfer_Encoding: chunked" => "a\r\n0123456789\r\n0\r\n\r\n"}.each do |lines, body|
      it "times the idle connection after a body framed by #{lines.inspect} as idle, not as a new request" do
        with_limited_server(limited_app(header: 0.6, read: 0.5, keep_alive: 3.0)) do |address|
          socket = TCPSocket.new(address.address, address.port)
          socket << "POST /body HTTP/1.1\r\nHost: x\r\n#{lines}\r\n\r\n#{body}"
          socket.flush
          socket.read_timeout = 3.seconds
          socket.gets.to_s.should start_with("HTTP/1.1 200")
          loop { break if socket.gets.to_s.strip.empty? }
          buffer = Bytes.new(7)
          socket.read_fully(buffer)
          String.new(buffer).should eq "body 10"
          sleep 1.2.seconds # longer than header_timeout and read_timeout, within keep_alive_timeout
          socket << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
          socket.flush
          text, _, _ = read_all(socket)
          text.should start_with("HTTP/1.1 200")
          text.should contain("hello")
        end
      end
    end

    it "times a request pipelined behind an underscore-framed body as headers, from the end of the response" do
      with_limited_server(limited_app(header: 0.6, read: 3.0, keep_alive: 5.0)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent_Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\nHost: x\r\n"
        socket.flush
        text, closed, seconds = read_all(socket, 6.seconds)
        closed.should be_true
        text.scan(/HTTP\/1.1 \d+/).map(&.[0]).should eq ["HTTP/1.1 200", "HTTP/1.1 408"]
        seconds.should be < 2.0
      end
    end
  end

  {false, true}.each do |tls|
    transport = tls ? "TLS" : "plain HTTP"

    describe "a chunked body (#{transport})" do
      {"framed" => CHUNKED, "of unknown length" => UNKNOWN_CHUNKED}.each do |kind, body|
        it "#{kind}: ends where it ends or is answered, and the next request's headers are timed with header_timeout" do
          with_server(limited_app(header: 0.6, read: 3.0, keep_alive: 5.0), tls) do |address|
            io, tcp = connect(address, tls)
            io << "POST /body HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n#{body}"
            io.flush
            sleep 0.3.seconds
            drip(io, SLOW_HEADERS, 0.15.seconds)
            text, seconds = read_until_close(io, tcp)
            statuses(text).should eq(tls ? ["HTTP/1.1 200"] : ["HTTP/1.1 200", "HTTP/1.1 408"])
            seconds.should be < 1.5 # not read_timeout (3 s)
          end
        end
      end

      it "of unknown length: is timed as a body while the handler reads it" do
        with_server(limited_app(header: 0.6, read: 0.4, keep_alive: 3.0), tls, quiet_rescuer) do |address|
          io, tcp = connect(address, tls)
          io << "POST /body HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhel"
          io.flush
          text, seconds = read_until_close(io, tcp)
          statuses(text).should eq ["HTTP/1.1 408"]
          seconds.should be < 1.5 # read_timeout, not keep_alive_timeout (3 s)
        end
      end
    end
  end

  describe "the worst case of a body that hardly comes" do
    it "cuts it about read_timeout after it starts, however the drip is paced" do
      # A byte just before the read would time out: the credit runs down to what one byte earns at min_body_rate.
      with_limited_server(limited_app(read: 0.5, rate: 1024)) do |address|
        socket = TCPSocket.new(address.address, address.port)
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"
        socket.flush
        started = Time.instant
        spawn do
          100.times do
            sleep 0.45.seconds
            socket << "a"
            socket.flush
          end
        rescue IO::Error
        end
        _, closed, _ = read_all(socket, 8.seconds)
        closed.should be_true
        # At most read_timeout + its bytes / min_body_rate (0.5 s and a few ms), well under 2 x read_timeout.
        (Time.instant - started).should be < 0.8.seconds
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

    it "lets a fast start buy at most read_timeout of waiting for a drip after it" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.read_timeout = 2.seconds
      limits.min_body_rate = 1024
      clock = Azu::RequestClock.new(limits)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".to_slice)
      clock.before_read
      clock.after_read(Bytes.new(50_000_000)) # at 1 KB/s that would earn 13 hours
      3.times do                              # then a byte per 0.5 s of waiting
        clock.before_read
        sleep 0.5.seconds
        clock.after_read(Bytes.new(1))
      end
      clock.before_read.not_nil!.should be < 0.6.seconds
    end

    it "spends the body's credit only on the time the server waits for the client" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.read_timeout = 1.second
      limits.min_body_rate = 1024
      clock = Azu::RequestClock.new(limits)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".to_slice)
      sleep 1.2.seconds # the handler is busy: not the client's time
      clock.before_read.not_nil!.should be > 0.9.seconds
      sleep 0.4.seconds # waits for the client, which sends one byte
      clock.after_read(Bytes.new(1))
      left = clock.before_read.not_nil!
      left.should be < 0.7.seconds
      left.should be > 0.3.seconds
    end

    it "raises ClientTooSlow, an IO::TimeoutError, when a deadline has passed" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.header_timeout = 0.1.seconds
      clock = Azu::RequestClock.new(limits)
      sleep 0.2.seconds
      expect_raises(Azu::ServerLimits::ClientTooSlow) { clock.before_read }
      Azu::ServerLimits::ClientTooSlow.new.should be_a(IO::TimeoutError)
    end

    it "counts every response the server wrote between two reads of the socket" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.before_read
      clock.after_read("GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n".to_slice)
      2.times { clock.after_write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".to_slice) }
      clock.before_read # the server waits for a third request
      clock.phase.idle?.should be_true

      clock.after_read(("GET / HTTP/1.1\r\n\r\n" * 3).to_slice)
      3.times { clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice) }
      clock.before_read
      clock.phase.idle?.should be_true
    end

    it "keeps timing the body of the last request read with the ones answered before it" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.before_read
      clock.after_read("GET / HTTP/1.1\r\n\r\nPOST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice)
      clock.before_read # the rest of the POST body
      clock.phase.body?.should be_true
      clock.after_read("cde".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice)
      clock.before_read
      clock.phase.idle?.should be_true
    end

    it "does not give a body fresh credit when its handler writes before it has read it all (full duplex)" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.read_timeout = 1.second
      limits.min_body_rate = 1024
      clock = Azu::RequestClock.new(limits)
      clock.before_read
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\nab".to_slice)
      clock.before_read
      sleep 0.6.seconds
      clock.after_read("c".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n\r\nc".to_slice) # an echo
      clock.before_read.not_nil!.should be < 0.6.seconds
      clock.phase.body?.should be_true
    end

    it "does not take 100 Continue for the response" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".to_slice)
      clock.after_write("HTTP/1.1 100 Continue\r\n\r\n".to_slice)
      clock.before_read
      clock.phase.body?.should be_true
      clock.after_read("hello".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n".to_slice)
      clock.before_read
      clock.phase.idle?.should be_true
    end

    it "keeps timing a body of unknown length as a body until its response is written" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhel".to_slice)
      clock.before_read
      clock.phase.body?.should be_true
      clock.after_read("lo\r\n0\r\n\r\n".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice)
      clock.before_read
      clock.phase.idle?.should be_true
    end

    it "times a body of unknown length after a request answered from the buffer as a body" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("GET / HTTP/1.1\r\n\r\nPOST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhel".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice)
      clock.before_read
      clock.phase.body?.should be_true
    end

    it "times what follows a body read in full as the next request, though nothing was written after it" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\n".to_slice)
      clock.after_write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_slice) # all of it, before the body
      clock.before_read
      clock.phase.body?.should be_true
      clock.after_read("ab".to_slice)
      clock.before_read
      clock.phase.idle?.should be_true
    end

    it "frames a chunked body, so the request after it is timed as headers once the body is answered" do
      clock = Azu::RequestClock.new(Azu::ServerLimitsConfiguration.new)
      clock.after_read("GET / HTTP/1.1\r\n\r\nPOST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\nGE".to_slice)
      2.times { clock.after_write("HTTP/1.1 200 OK\r\n\r\n".to_slice) }
      clock.before_read
      clock.phase.headers?.should be_true
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

  describe "a timeout that is not the client's" do
    it "is the server's error, answered 500 by Rescuer" do
      backend = ::Log::MemoryBackend.new
      log = ::Log.new("upstream_spec", backend, :debug)
      with_limited_server(limited_app, [Azu::Handler::Rescuer.new(log)] of HTTP::Handler) do |address|
        HTTP::Client.new(address.address, address.port).get("/upstream").status_code.should eq 500
        backend.entries.map(&.message).none?(&.includes?("-> 408")).should be_true
      end
    end
  end

  describe "the connection gate" do
    it "gives the place back even when closing the socket fails" do
      limits = Azu::ServerLimitsConfiguration.new
      limits.max_connections = 2
      listener = Azu::LimitedTCPServer.new("127.0.0.1", 0, limits)
      client = TCPSocket.new("127.0.0.1", listener.local_address.port)
      accepted = listener.accept?.not_nil!
      listener.gate.open.should eq 1
      LibC.close(accepted.fd) # closed under it: its own close fails with EBADF
      expect_raises(IO::Error) { accepted.close }
      listener.gate.open.should eq 0
    ensure
      client.try &.close
      listener.try &.close
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

    it "cuts a client that drips one TLS record of its headers, with the header deadline" do
      server, address = tls_server.call(limited_app(header: 1.0, read: 5.0, keep_alive: 5.0))
      drip = Atomic(Bool).new(false)
      proxy = TCPServer.new("127.0.0.1", 0)
      spawn do
        client = proxy.accept? || next
        upstream = TCPSocket.new(address.address, address.port)
        spawn do
          IO.copy(upstream, client) rescue nil
          client.close rescue nil
        end
        buffer = Bytes.new(4096)
        loop do
          count = client.read(buffer)
          break if count == 0
          buffer[0, count].each do |byte|
            upstream.write_byte(byte)
            upstream.flush
            sleep 0.05.seconds if drip.get
          end
        end
      rescue IO::Error
      ensure
        upstream.try { |socket| socket.close rescue nil }
      end
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        sleep 0.2.seconds # the handshake's last bytes reach the server at full speed: only the request drips
        drip.set(true)
        started = Time.instant
        socket << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" # one record, ~80 bytes: 4 s at this pace
        socket.flush
        tcp.read_timeout = 8.seconds
        text = (socket.gets_to_end rescue "")
        text.should_not contain("hello")
        (Time.instant - started).should be < 2.seconds
      ensure
        proxy.close
        server.close
      end
    end

    it "takes a body record that comes slower than read_timeout but above min_body_rate" do
      # One 4000-byte record at 2000 B/s: 2 s to arrive, four times read_timeout, twice min_body_rate.
      server, address = tls_server.call(limited_app(header: 1.0, read: 0.5, keep_alive: 5.0, rate: 1000))
      proxy, drip = drip_proxy(address, 200, 0.1.seconds)
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        socket.sync = true
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 4000\r\nConnection: close\r\n\r\n"
        sleep 0.2.seconds
        drip.turn_on
        started = Time.instant
        socket << "z" * 4000
        text, _ = read_until_close(socket, tcp, 8.seconds)
        text.should contain("body 4000")
        (Time.instant - started).should be > 1.5.seconds
      ensure
        proxy.close
        server.close
      end
    end

    it "cuts a body record dripped below min_body_rate about read_timeout after it starts" do
      server, address = tls_server.call(limited_app(header: 1.0, read: 0.6, keep_alive: 5.0, rate: 1024))
      proxy, drip = drip_proxy(address, 1, 0.05.seconds)
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        socket.sync = true
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n"
        sleep 0.2.seconds
        drip.turn_on
        started = Time.instant
        spawn { socket << "z" * 2000 rescue nil } # 20 B/s: 100 s at this pace
        text, _ = read_until_close(socket, tcp, 8.seconds)
        text.should_not contain("body 2000")
        (Time.instant - started).should be < 1.5.seconds
      ensure
        proxy.close
        server.close
      end
    end

    it "takes a body record dripped within read_timeout per read when min_body_rate is 0" do
      # One 4000-byte record over 2 s, four times read_timeout: each read of it comes within read_timeout.
      server, address = tls_server.call(limited_app(header: 1.0, read: 0.5, keep_alive: 5.0, rate: 0))
      proxy, drip = drip_proxy(address, 200, 0.1.seconds)
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        socket.sync = true
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 4000\r\nConnection: close\r\n\r\n"
        sleep 0.2.seconds
        drip.turn_on
        socket << "z" * 4000
        text, _ = read_until_close(socket, tcp, 8.seconds)
        text.should contain("body 4000")
      ensure
        proxy.close
        server.close
      end
    end

    it "gives a body record that starts fast at most read_timeout of credit for the drip after it" do
      # 15 000 bytes at once earn 15 s at 1000 B/s; the rest of the record then comes at 10 B/s.
      server, address = tls_server.call(limited_app(header: 1.0, read: 0.5, keep_alive: 5.0, rate: 1000))
      proxy, drip = drip_proxy(address, 1, 0.1.seconds, burst: 15_000)
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        socket.sync = true
        socket << "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 16000\r\nConnection: close\r\n\r\n"
        sleep 0.2.seconds
        drip.turn_on
        started = Time.instant
        spawn { socket << "z" * 16000 rescue nil } # one record
        text, _ = read_until_close(socket, tcp, 20.seconds)
        text.should_not contain("body 16000")
        (Time.instant - started).should be < 2.seconds
      ensure
        proxy.close
        server.close
      end
    end

    it "does not let the bytes of a header record earn time, however fast they come" do
      # One record of ~1000 header bytes at 200 B/s, twice min_body_rate: 5 s to arrive, header_timeout is 1 s.
      server, address = tls_server.call(limited_app(header: 1.0, read: 5.0, keep_alive: 5.0, rate: 100))
      proxy, drip = drip_proxy(address, 20, 0.1.seconds)
      begin
        tcp = TCPSocket.new("127.0.0.1", proxy.local_address.port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, client_context, hostname: "localhost")
        socket.sync = true
        sleep 0.2.seconds # the handshake's last bytes reach the server at full speed: only the request drips
        drip.turn_on
        started = Time.instant
        spawn { socket << "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: #{"a" * 950}\r\nConnection: close\r\n\r\n" rescue nil }
        text, _ = read_until_close(socket, tcp, 10.seconds)
        text.should_not contain("hello")
        (Time.instant - started).should be < 2.seconds
      ensure
        proxy.close
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
