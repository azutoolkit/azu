# Server-side benchmarks of Azu::Spark: one binary, four commands.
#
#   crystal build --release -o bin/spark_server_bench benchmark/spark/server_bench.cr
#   spark_server_bench serve [--nodelay] [--ttl SECONDS]             # a Spark server on a free port; prints PORT=<n>
#   spark_server_bench load events   --port P --conns 10 --components 5 --events 2000 [--eid off]
#   spark_server_bench load fanout   --port P --conns 100 --messages 40 --interval-ms 25
#   spark_server_bench load memory   --port P --conns 200 --components 5
#   spark_server_bench micro                         # Benchmark.ips of the bookkeeping; the JSON is the line "RESULT {...}"
#
# The server and the load generator are separate processes (the runner, benchmark/spark/server.mjs,
# starts both), so the server's single thread is not shared with the WebSocket clients. Every `load`
# command prints one JSON object on stdout. The `events` latencies are closed loop: a client sends its next
# event only after the previous reply, so a stall delays the sends that would have queued behind it and the
# percentiles understate the tail of an open-loop arrival (a lower bound, most of all p99). See benchmark/spark/README.md for what the numbers mean.
require "benchmark"
require "http/client"
require "http/server"
require "http/web_socket"
require "json"
require "../../src/azu"

module SparkBench
  TOPIC = "bench"

  # `serve --nodelay` sets TCP_NODELAY on accepted sockets (see `Control#stats`: the diff and the reply of
  # an event are two small writes, which Nagle's algorithm and the client's delayed ACK can hold apart).
  class_property? nodelay = false
  class_property? client_nodelay = false

  # Handles events; carries no subscriptions.
  class Counter < Azu::Spark::Component
    mountable

    state count : Int32 = 0

    event def increment : Nil
      self.count += 1
    end

    def render
      div do
        span "count=#{count}"
      end
    end
  end

  # Subscribes to the topic and re-renders with the payload of every message.
  class Listener < Azu::Spark::Component
    mountable

    state stamp : String = ""

    def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
      socket.subscribe(TOPIC)
    end

    def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
      self.stamp = message.payload
    end

    def render
      span "stamp=#{stamp}"
    end
  end

  # The control plane of the server process: pages to join, memory figures, and a publisher.
  class Control
    include HTTP::Handler

    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      case request.path
      when "/pages"   then pages(context)
      when "/stats"   then stats(context)
      when "/publish" then publish(context)
      when "/stop"
        context.response.print("bye")
        context.response.flush
        spawn { exit 0 }
      else call_next(context)
      end
    end

    private def pages(context : HTTP::Server::Context) : Nil
      count = context.request.query_params["n"].to_i
      kind = context.request.query_params["kind"]
      body = String.build do |io|
        count.times do
          html = kind == "listener" ? Azu::Spark.render(Listener) : Azu::Spark.render(Counter)
          io << html.match!(/data-spark-id='([^']+)'/)[1] << ' ' << html.match!(/data-spark-token='([^']+)'/)[1] << '\n'
        end
      end
      context.response.print(body)
    end

    private def stats(context : HTTP::Server::Context) : Nil
      GC.collect if context.request.query_params["gc"]? == "1"
      heap = GC.stats
      rss_pages = File.read("/proc/self/statm").split[1].to_i64
      context.response.content_type = "application/json"
      context.response.print({
        rss_kb:      rss_pages * 4,
        heap_kb:     heap.heap_size // 1024,
        used_kb:     (heap.heap_size - heap.free_bytes) // 1024,
        connections: Azu::Spark.connection_count,
      }.to_json)
    end

    private def publish(context : HTTP::Server::Context) : Nil
      query = context.request.query_params
      count = query["count"].to_i
      interval = query["interval_ms"]?.try(&.to_i) || 0
      count.times do
        Azu::PubSub.broadcast(TOPIC, Time.utc.to_unix_ns.to_s)
        sleep interval.milliseconds if interval > 0
      end
      context.response.print("ok")
    end
  end

  def self.configure : Nil
    config = Azu::Spark.config
    config.events_per_second = 1_000_000.0
    config.event_burst = 1_000_000
    config.max_components = 5000
    config.idle_timeout = 10.minutes
    config.heartbeat_interval = 10.minutes
  end

  def self.serve(ttl : Int32) : Nil
    configure
    # A server nobody stops (a crashed runner) ends itself after *ttl* seconds.
    spawn do
      sleep ttl.seconds
      exit 0
    end
    server = HTTP::Server.new([Azu::Channel::Upgrader.new(Azu::Spark::Connection), Control.new])
    address = server.bind_tcp("127.0.0.1", 0)
    puts "PORT=#{address.port}"
    STDOUT.flush
    server.listen
  end

  # ---- load generator ---------------------------------------------------------------------

  alias Root = NamedTuple(id: String, token: String)

  def self.fetch_roots(port : Int32, kind : String, count : Int32) : Array(Root)
    body = HTTP::Client.get("http://127.0.0.1:#{port}/pages?n=#{count}&kind=#{kind}").body
    body.each_line.map { |line| id, token = line.split(' '); {id: id, token: token} }.to_a
  end

  def self.fetch_stats(port : Int32, gc : Bool = true) : JSON::Any
    JSON.parse(HTTP::Client.get("http://127.0.0.1:#{port}/stats?gc=#{gc ? 1 : 0}").body)
  end

  def self.percentile(sorted : Array(Float64), q : Float64) : Float64
    return 0.0 if sorted.empty?
    sorted[((sorted.size - 1) * q).round.to_i]
  end

  # A WebSocket client that joins its roots and hands every text frame to *frames*.
  class Client
    getter socket : HTTP::WebSocket
    getter replies = ::Channel(Int64).new(4096)

    def initialize(port : Int32, @on_diff : Proc(String, Nil)? = nil)
      headers = HTTP::Headers{"Origin" => "http://127.0.0.1:#{port}"}
      @socket = HTTP::WebSocket.new("127.0.0.1", "/spark", port, headers: headers)
      @socket.on_message { |text| received(text) }
      spawn do
        @socket.run
      rescue IO::Error
      end
    end

    @id = 0_i64

    def next_id : Int64
      @id += 1
    end

    private def received(text : String) : Nil
      if text.includes?("\"type\":\"reply\"")
        id = JSON.parse(text)["id"]?.try(&.as_i64?)
        @replies.send(id) if id
      elsif text.includes?("\"type\":\"diff\"")
        @on_diff.try(&.call(text))
      end
    end

    def join(roots : Array(Root)) : Nil
      roots.each do |root|
        id = next_id
        @socket.send({v: 1, type: "join", id: id, token: root[:token], params: {} of String => String}.to_json)
      end
      roots.size.times { @replies.receive }
    end

    def close : Nil
      @socket.close
    rescue IO::Error
    end
  end

  def self.connect_all(port : Int32, kind : String, conns : Int32, components : Int32, on_diff : Proc(String, Nil)? = nil) : Array({Client, Array(Root)})
    roots = fetch_roots(port, kind, conns * components)
    clients = [] of {Client, Array(Root)}
    joined = ::Channel(Nil).new
    conns.times do |c|
      mine = roots[c * components, components]
      client = Client.new(port, on_diff)
      clients << {client, mine}
      spawn do
        client.join(mine)
        joined.send(nil)
      end
    end
    conns.times { joined.receive }
    clients
  end

  def self.events(port : Int32, conns : Int32, components : Int32, per_conn : Int32, eid : Bool) : Nil
    clients = connect_all(port, "counter", conns, components)
    latencies = [] of Float64
    finished = ::Channel(Nil).new
    warmup = 20
    started = Time.instant
    clients.each do |(client, roots)|
      spawn do
        numbers = Hash(String, Int64).new(0_i64)
        (per_conn + warmup).times do |i|
          root = roots[i % roots.size]
          numbers[root[:id]] += 1
          id = client.next_id
          frame = {v: 1, type: "event", id: id, target: root[:id], event: "increment", payload: {} of String => String, eid: eid ? numbers[root[:id]] : nil}.to_json
          if i == warmup
            started = Time.instant if client == clients.first[0]
          end
          sent = Time.instant
          client.socket.send(frame)
          client.replies.receive
          latencies << (Time.instant - sent).total_milliseconds if i >= warmup
        end
        finished.send(nil)
      end
    end
    clients.size.times { finished.receive }
    elapsed = Time.instant - started
    sorted = latencies.sort
    clients.each(&.[0].close)
    puts({
      events:       sorted.size,
      events_per_s: sorted.size / elapsed.total_seconds,
      p50_ms:       percentile(sorted, 0.50),
      p99_ms:       percentile(sorted, 0.99),
      mean_ms:      sorted.sum / sorted.size,
      connections:  conns,
      components:   components,
      eid:          eid,
    }.to_json)
  end

  def self.fanout(port : Int32, conns : Int32, messages : Int32, interval_ms : Int32) : Nil
    latencies = [] of Float64
    received = 0
    first_publish = Time.instant
    last_arrival = Time.instant
    on_diff = ->(text : String) do
      if match = text.match(/stamp=(\d+)/)
        latencies << (Time.utc.to_unix_ns - match[1].to_i64) / 1_000_000.0
        received += 1
        last_arrival = Time.instant
      end
      nil
    end
    clients = connect_all(port, "listener", conns, 1, on_diff)
    expected = conns * messages
    first_publish = Time.instant
    spawn { HTTP::Client.get("http://127.0.0.1:#{port}/publish?count=#{messages}&interval_ms=#{interval_ms}") }
    deadline = Time.instant + 30.seconds
    while received < expected && Time.instant < deadline
      sleep 5.milliseconds
    end
    elapsed = last_arrival - first_publish
    sorted = latencies.sort
    clients.each(&.[0].close)
    puts({
      deliveries:       received,
      expected:         expected,
      lost:             expected - received,
      deliveries_per_s: received / Math.max(elapsed.total_seconds, 0.000001),
      p50_ms:           percentile(sorted, 0.50),
      p99_ms:           percentile(sorted, 0.99),
      connections:      conns,
      interval_ms:      interval_ms,
    }.to_json)
  end

  def self.memory(port : Int32, conns : Int32, components : Int32) : Nil
    before = fetch_stats(port)
    clients = connect_all(port, "counter", conns, components)
    sleep 200.milliseconds
    during = fetch_stats(port)
    clients.each(&.[0].close)
    sleep 500.milliseconds
    after = fetch_stats(port)
    delta = ->(key : String) { (during[key].as_i64 - before[key].as_i64).to_f / conns }
    puts({
      connections:           conns,
      components:            components,
      open_connections:      during["connections"].as_i64,
      rss_kb_per_conn:       delta.call("rss_kb"),
      used_kb_per_conn:      delta.call("used_kb"),
      used_kb_per_component: delta.call("used_kb") / components,
      used_kb_after_close:   after["used_kb"].as_i64,
    }.to_json)
  end

  # ---- micro benchmarks -------------------------------------------------------------------

  def self.micro : Nil
    session = Azu::Spark::Session.new(Azu::Spark::ConnectionInfo.detached, true) { |_| }
    session.start(Counter.new, "root", {} of String => String, Azu::Spark::Params.from_strings({} of String => String))
    empty = Azu::Spark::Params.new
    update = session.event("root", "increment", empty)
    with_eid = %({"v":1,"type":"event","id":7,"target":"root","event":"increment","payload":{},"eid":5,"gen":"abc123"})
    without = %({"v":1,"type":"event","id":7,"target":"root","event":"increment","payload":{}})
    numbers = 0_i64
    sink = 0

    job = Benchmark.ips(warmup: 0.3.seconds, calculation: 0.7.seconds, interactive: false) do |x|
      x.report("session.accept(no eid)") { sink += session.accept("root", nil, nil) ? 1 : 0 }
      x.report("session.accept(new eid)") { sink += session.accept("root", numbers += 1, nil) ? 1 : 0 }
      x.report("session.accept(duplicate eid)") { sink += session.accept("root", 1_i64, nil) ? 1 : 0 }
      x.report("Protocol.reply(no ack)") { sink += Azu::Spark::Protocol.reply(7_i64, "root").bytesize }
      x.report("Protocol.reply(ack)") { sink += Azu::Spark::Protocol.reply(7_i64, "root", ack: 5_i64).bytesize }
      x.report("Protocol.diff(no ack)") { sink += Azu::Spark::Protocol.diff(3_i64, update).bytesize }
      x.report("Protocol.diff(ack)") { sink += Azu::Spark::Protocol.diff(3_i64, update, 5_i64).bytesize }
      x.report("Inbound.from_json(no eid)") { sink += Azu::Spark::Protocol::Inbound.from_json(without).id.not_nil!.to_i }
      x.report("Inbound.from_json(eid+gen)") { sink += Azu::Spark::Protocol::Inbound.from_json(with_eid).id.not_nil!.to_i }
      x.report("session.event(increment)") { sink += session.event("root", "increment", empty).patches.size }
    end
    result = job.items.map do |item|
      {label: item.label, ns_per_op: 1_000_000_000.0 / item.mean, relative_stddev: item.relative_stddev / 100.0}
    end
    puts "RESULT #{result.to_json}"
    STDERR.puts "sink=#{sink}"
  end
end

class TCPServer
  def accept? : TCPSocket?
    socket = previous_def
    socket.tcp_nodelay = true if socket && SparkBench.nodelay?
    socket
  end
end

# The load generator's own sockets: its frames are small writes too, and the benchmark must not measure
# the generator's delayed ACKs (a browser sends its frames in one write). Only the `load` commands use it.
class TCPSocket
  def initialize(host : String, port, dns_timeout = nil, connect_timeout = nil, blocking = false)
    previous_def
    self.tcp_nodelay = true if SparkBench.client_nodelay?
  end
end

def option(name : String, default : String) : String
  index = ARGV.index(name)
  index ? ARGV[index + 1] : default
end

case ARGV[0]?
when "serve"
  SparkBench.nodelay = ARGV.includes?("--nodelay")
  SparkBench.serve(option("--ttl", "900").to_i)
when "micro" then SparkBench.micro
when "load"
  SparkBench.client_nodelay = true
  port = option("--port", "0").to_i
  case ARGV[1]?
  when "events"
    SparkBench.events(port, option("--conns", "10").to_i, option("--components", "1").to_i, option("--events", "1000").to_i, option("--eid", "on") == "on")
  when "fanout"
    SparkBench.fanout(port, option("--conns", "100").to_i, option("--messages", "40").to_i, option("--interval-ms", "25").to_i)
  when "memory"
    SparkBench.memory(port, option("--conns", "100").to_i, option("--components", "1").to_i)
  else
    abort "usage: load events|fanout|memory"
  end
else
  abort "usage: spark_server_bench serve | load events|fanout|memory | micro"
end
