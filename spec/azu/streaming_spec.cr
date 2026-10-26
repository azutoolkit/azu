require "../spec_helper"
require "http/client"

# Signals between a spec and the producers it started; each spec drains what it uses.
private GATE     = ::Channel(Nil).new
private STOPPED  = ::Channel(String).new(8)
private PRODUCED = [] of String

private alias EventStream = Azu::Response::EventStream
private alias Event = Azu::Response::EventStream::Event

# Blocks until the spec opens the gate; gives up after a while so a failed spec cannot leave a producer
# waiting to steal the next spec's signal.
private def await_gate : Nil
  select
  when GATE.receive
  when timeout(5.seconds)
  end
end

private struct Ticker
  include Azu::Endpoint(Azu::Request, EventStream)

  get "/st-ticks"

  def call : EventStream
    EventStream.new(heartbeat: 20.milliseconds) do |events|
      PRODUCED << "run"
      events.send Event.new("first", id: "1")
      await_gate
      events.send Event.new("second\nline", event: "late", id: "2")
    end
  end
end

private struct Resume
  include Azu::Endpoint(Azu::Request, EventStream)

  get "/st-resume"

  def call : EventStream
    EventStream.new do |events|
      events.send "resumed after #{events.last_event_id.inspect}"
    end
  end
end

private struct Forever
  include Azu::Endpoint(Azu::Request, EventStream)

  get "/st-forever"

  def call : EventStream
    EventStream.new(heartbeat: 20.milliseconds, retry: 3.seconds) do |events|
      while events.open?
        events.send Event.new("tick")
        events.sleep 10.milliseconds
      end
    ensure
      STOPPED.send "producer"
    end.on_close { STOPPED.send "on_close" }
  end
end

private struct Forwarding
  include Azu::Endpoint(Azu::Request, EventStream)

  get "/st-forward"

  def call : EventStream
    EventStream.new do |events|
      queue = ::Channel(Int32).new
      spawn do
        3.times { |i| queue.send i }
        queue.close
      end
      events.forward(queue) { |number| Event.json({n: number}, event: "n") }
    end
  end
end

private struct Csv
  include Azu::Endpoint(Azu::Request, Azu::Response::Stream)

  get "/st-csv"

  def call : Azu::Response::Stream
    Azu::Response::Stream.new("text/csv") do |sink|
      sink << "a,b\n"
      await_gate
      sink << "c,d\n"
    end
  end
end

private struct Endless
  include Azu::Endpoint(Azu::Request, Azu::Response::Stream)

  get "/st-endless"

  def call : Azu::Response::Stream
    Azu::Response::Stream.new do |sink|
      loop do
        sink << "x" * 1024
        sleep 5.milliseconds
      end
    end.on_close { STOPPED.send "stream closed" }
  end
end

private struct Closing
  include Azu::Endpoint(Azu::Request, Azu::Response::Stream)

  get "/st-closing"

  def call : Azu::Response::Stream
    Azu::Response::Stream.new do |sink|
      sink << "body"
    end.on_close { STOPPED.send "closed" }
  end
end

private struct Broken
  include Azu::Endpoint(Azu::Request, Azu::Response::Stream)

  get "/st-broken"

  def call : Azu::Response::Stream
    Azu::Response::Stream.new do |sink|
      sink << "partial"
      raise "boom"
    end.on_close { STOPPED.send "closed" }
  end
end

private struct Failing
  include Azu::Endpoint(Azu::Request, EventStream)

  get "/st-failing"

  def call : EventStream
    EventStream.new do |events|
      events.send "before"
      raise "producer failed"
    end
  end
end

private struct FlushFirst
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response.flush
    context.response << "hello hello hello"
    context
  end
end

private struct Plain
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "hello hello hello"
    context
  end
end

private def streaming_app : Azu::App
  app = Azu::App.new
  app.routes do
    endpoint Ticker
    endpoint Resume
    endpoint Forever
    endpoint Forwarding
    endpoint Csv
    endpoint Endless
    get "/st-plain", Plain.new
    get "/st-flush-first", FlushFirst.new
    endpoint Closing
    endpoint Broken
    endpoint Failing
  end
  app
end

private def serve(app : Azu::App, handlers = [] of HTTP::Handler) : String
  server = app.server(handlers)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  "http://#{address.address}:#{address.port}"
end

# The next line of a body, failing the spec instead of hanging when the server sends none.
private def next_line(io : IO, within : Time::Span = 3.seconds) : String?
  line = ::Channel(String?).new(1)
  spawn { line.send((io.gets(chomp: false) rescue nil)) }
  select
  when text = line.receive
    text
  when timeout(within)
    fail "no line within #{within}"
  end
end

private def producer_fibers : Int32
  count = 0
  Fiber.each { |fiber| count += 1 if fiber.name == "azu-event-stream" }
  count
end

# Reads lines until the block accepts one.
private def read_until(io : IO, & : String -> Bool) : Array(String)
  lines = [] of String
  while line = next_line(io)
    lines << line
    break if yield line
  end
  lines
end

private def received(channel : ::Channel(String), within : Time::Span = 3.seconds) : String
  select
  when message = channel.receive
    message
  when timeout(within)
    fail "nothing within #{within}"
  end
end

describe Azu::Response::EventStream::Event do
  it "writes one data line per line of data, then a blank line" do
    Event.new("a\nb\r\nc\rd").to_s.should eq "data: a\ndata: b\ndata: c\ndata: d\n\n"
  end

  it "writes id, event and retry before the data" do
    Event.new("x", id: "7", event: "tick", retry: 2.seconds).to_s.should eq "id: 7\nevent: tick\nretry: 2000\ndata: x\n\n"
  end

  it "keeps an empty line of data and an empty event" do
    Event.new("a\n").to_s.should eq "data: a\ndata: \n\n"
    Event.new.to_s.should eq "data: \n\n"
  end

  it "builds an event from JSON" do
    Event.json({n: 1}, event: "n").to_s.should eq %(event: n\ndata: {"n":1}\n\n)
  end

  it "refuses a line break in a field, which would end the event early" do
    expect_raises(ArgumentError) { Event.new("x", event: "a\nb") }
    expect_raises(ArgumentError) { Event.new("x", id: "a\rb") }
    expect_raises(ArgumentError) { Event.new("x", id: "a\0b") }
  end
end

describe Azu::Response::EventStream do
  it "sends events as they happen, with the headers of a stream" do
    base = serve(streaming_app)

    HTTP::Client.get("#{base}/st-ticks") do |response|
      response.headers["Content-Type"].should eq "text/event-stream"
      response.headers["Cache-Control"].should eq "no-cache"
      response.headers["X-Accel-Buffering"].should eq "no"
      response.headers["Transfer-Encoding"].should eq "chunked"
      io = response.body_io

      # The producer waits for GATE after the first event: it can only arrive if it was flushed.
      read_until(io, &.starts_with?("data: first")).should eq [":\n", "\n", "id: 1\n", "data: first\n"]
      next_line(io).should eq "\n"
      GATE.send(nil)

      rest = io.gets_to_end
      rest.should contain "event: late\nid: 2\n".sub("event: late\nid: 2", "id: 2\nevent: late")
      rest.should contain "data: second\ndata: line\n\n"
    end
  end

  it "sends a heartbeat comment while the producer is silent" do
    base = serve(streaming_app)

    HTTP::Client.get("#{base}/st-ticks") do |response|
      lines = read_until(response.body_io, &.starts_with?(": heartbeat"))
      lines.last.should eq ": heartbeat\n"
      GATE.send(nil)
    end
  end

  it "tells the producer the Last-Event-ID the client reconnected with" do
    base = serve(streaming_app)
    headers = HTTP::Headers{"Last-Event-ID" => "42"}

    HTTP::Client.get("#{base}/st-resume", headers).body.should contain %(data: resumed after "42")
    HTTP::Client.get("#{base}/st-resume?lastEventId=7").body.should contain %(data: resumed after "7")
    HTTP::Client.get("#{base}/st-resume").body.should contain "data: resumed after nil"
  end

  it "ends when the producer returns and sends the events a forwarded channel delivers" do
    body = HTTP::Client.get("#{serve(streaming_app)}/st-forward").body

    body.should eq %(:\n\nevent: n\ndata: {"n":0}\n\nevent: n\ndata: {"n":1}\n\nevent: n\ndata: {"n":2}\n\n)
  end

  it "opens with the retry the client should wait before reconnecting" do
    base = serve(streaming_app)

    HTTP::Client.get("#{base}/st-forever") do |response|
      next_line(response.body_io).should eq "retry: 3000\n"
    end
    received(STOPPED)
    received(STOPPED)
  end

  it "ends within the shutdown timeout, so the drain does not wait for it" do
    app = streaming_app
    base = serve(app)
    ended = ::Channel(String).new(1)
    HTTP::Client.get("#{base}/st-forever") do |response|
      next_line(response.body_io)
      spawn { ended.send response.body_io.gets_to_end }

      started = Time.instant
      app.stop(5.seconds).should be_true
      (Time.instant - started).should be < 2.seconds
      received(ended).should contain "data: tick"
    end
    received(STOPPED).should_not be_empty
    received(STOPPED).should_not be_empty
  end

  it "stops the producer and runs on_close when the client goes away" do
    base = serve(streaming_app)
    before = producer_fibers

    HTTP::Client.get("#{base}/st-forever") { |response| next_line(response.body_io) }

    [received(STOPPED), received(STOPPED)].sort.should eq ["on_close", "producer"]
    wait_until { producer_fibers <= before }.should be_true
  end

  it "answers HEAD with the headers and starts no producer" do
    base = serve(streaming_app)
    PRODUCED.clear

    response = HTTP::Client.head("#{base}/st-ticks")

    response.headers["Content-Type"].should eq "text/event-stream"
    response.headers["X-Accel-Buffering"].should eq "no"
    response.body.should be_empty
    PRODUCED.should be_empty
  end

  it "tells the client when the producer fails" do
    body = HTTP::Client.get("#{serve(streaming_app)}/st-failing").body

    body.should contain "data: before\n\n"
    body.should end_with "event: error\ndata: The stream failed\n\n"
  end

  it "is not compressed, while other responses are" do
    base = serve(streaming_app, [Azu::Handler::Compression.new] of HTTP::Handler)
    headers = HTTP::Headers{"Accept-Encoding" => "gzip"}

    HTTP::Client.get("#{base}/st-resume", headers) do |response|
      response.headers["Content-Encoding"]?.should be_nil
      response.body_io.gets_to_end.should contain "data: resumed"
    end
    HTTP::Client.get("#{base}/st-plain", headers) { |response| response.headers["Content-Encoding"]?.should eq "gzip" }
  end
end

describe Azu::Handler::Compression do
  it "leaves the body intact when the handler flushed before its first write" do
    headers = HTTP::Headers{"Accept-Encoding" => "gzip"}

    HTTP::Client.get("#{serve(streaming_app, [Azu::Handler::Compression.new] of HTTP::Handler)}/st-flush-first", headers) do |response|
      io = response.body_io
      text = response.headers["Content-Encoding"]? == "gzip" ? Compress::Gzip::Reader.open(io, &.gets_to_end) : io.gets_to_end
      text.should eq "hello hello hello"
    end
  end
end

describe Azu::Response::Stream do
  it "flushes each write and ends the body when the block returns" do
    base = serve(streaming_app)

    HTTP::Client.get("#{base}/st-csv") do |response|
      response.headers["Content-Type"].should eq "text/csv"
      response.headers["Cache-Control"].should eq "no-cache"
      io = response.body_io
      next_line(io).should eq "a,b\n"
      GATE.send(nil)
      io.gets_to_end.should eq "c,d\n"
    end
  end

  it "answers HEAD with headers only" do
    response = HTTP::Client.head("#{serve(streaming_app)}/st-csv")

    response.headers["Content-Type"].should eq "text/csv"
    # the GET is chunked: the HEAD says so, rather than a Content-Length of 0
    response.headers["Transfer-Encoding"]?.should eq "chunked"
    response.headers["Content-Length"]?.should be_nil
    response.body.should be_empty
  end

  it "runs on_close for HEAD too" do
    HTTP::Client.head("#{serve(streaming_app)}/st-closing").headers["Cache-Control"].should eq "no-cache"

    received(STOPPED).should eq "closed"
  end

  it "logs an error raised after the headers are out, ends the body and runs on_close" do
    response = HTTP::Client.get("#{serve(streaming_app)}/st-broken")

    response.status_code.should eq 200
    response.body.should eq "partial"
    received(STOPPED).should eq "closed"
  end

  it "ends the block with the client's disconnection and runs on_close" do
    base = serve(streaming_app)

    HTTP::Client.get("#{base}/st-endless") { |response| response.body_io.read_string(10) }

    received(STOPPED).should eq "stream closed"
  end
end
