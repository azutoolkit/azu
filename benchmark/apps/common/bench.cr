# Fixtures every benchmark app shares, so that all frameworks answer with byte-identical bodies.
# The contract (routes, bodies, content types) is in docs/explanation/benchmarks.md; the conformance
# check (`scripts/bench.sh conformance`) fails when an app deviates.
require "json"
require "socket"

module Bench
  PLAINTEXT     = "Hello, World!"
  JSON_MESSAGE  = {message: "Hello, World!"}
  ROUTE_COUNT   =  100
  ITEM_COUNT    =   20
  DB_ROWS       = 1000
  DB_LIST_LIMIT =   20
  HOST          = ENV["HOST"]? || "127.0.0.1"
  PORT          = (ENV["PORT"]? || "3000").to_i
  DB_PATH       = ENV["BENCH_DB"]? || File.join(__DIR__, "..", "..", "db", "bench.sqlite3")
  # Same pool for every app: initial = max = idle, so no framework pays for opening connections under load
  DB_POOL = (ENV["BENCH_DB_POOL"]? || "4").to_i
  DB_URI  = "sqlite3://#{File.expand_path(DB_PATH)}?max_pool_size=#{DB_POOL}&initial_pool_size=#{DB_POOL}&max_idle_pool_size=#{DB_POOL}"

  # The template scenario renders these 20 rows. The name carries characters that must be escaped.
  struct Item
    getter id : Int32
    getter name : String
    getter price : Int32

    def initialize(@id, @name, @price)
    end
  end

  ITEMS = (1..ITEM_COUNT).map { |i| Item.new(i, "Item #{i} & <co>", i * 7) }

  # One row of the `items` table (see benchmark/db/seed.sh)
  record Row, id : Int64, name : String, value : Int64 do
    include JSON::Serializable
  end

  # TCP_NODELAY on accepted sockets. Crystal sockets leave Nagle on, which stalls small WebSocket frames by
  # about 40 ms (delayed ACK). Azu sets TCP_NODELAY on upgraded sockets itself; the baseline and Kemal get it from this
  # listener so that the WebSocket scenario compares frameworks and not a socket option. BENCH_WS_NODELAY=0 turns it
  # off for every app (the apps then run with the socket defaults; Azu gets WEBSOCKET_TCP_NODELAY=false).
  class NoDelayTCPServer < TCPServer
    def accept? : TCPSocket?
      super.try { |client| client.tap(&.tcp_nodelay = true) }
    end
  end

  def self.nodelay? : Bool
    ENV["BENCH_WS_NODELAY"]? != "0"
  end

  def self.tcp_server : TCPServer
    nodelay? ? NoDelayTCPServer.new(HOST, PORT) : TCPServer.new(HOST, PORT)
  end

  def self.route_body(n : Int32, id : String) : String
    {route: "resource#{n}", id: id}.to_json
  end
end
