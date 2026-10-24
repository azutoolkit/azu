# Fixtures every benchmark app shares, so that all frameworks answer with byte-identical bodies.
# The contract (routes, bodies, content types) is in benchmark/README.md; the conformance
# check (`scripts/bench.sh conformance`) fails when an app deviates.
require "json"
require "socket"
require "http/server"
require "log"

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

  def self.nodelay? : Bool
    ENV["BENCH_WS_NODELAY"]? != "0"
  end

  # Request logging is off in every app; the log level is the same too (the runner checks that nothing is written).
  def self.quiet_logs : Nil
    ::Log.setup(:warn)
  end

  def self.route_body(n : Int32, id : String) : String
    {route: "resource#{n}", id: id}.to_json
  end
end

# TCP_NODELAY on upgraded (WebSocket) sockets only, never on plain HTTP connections. Crystal sockets leave Nagle on,
# which stalls small WebSocket frames by about 40 ms (delayed ACK). Azu does this itself for upgraded sockets
# (`config.websocket.tcp_nodelay`); the baseline and Kemal use HTTP::Server's upgrade, so this wraps it the same way.
# BENCH_WS_NODELAY=0 turns it off for every app (Azu then gets tcp_nodelay = false).
class HTTP::Server::Response
  def upgrade(&block : IO ->) : Nil
    previous_def do |io|
      io.as?(TCPSocket).try(&.tcp_nodelay = true) if Bench.nodelay?
      block.call(io)
    end
  end
end
