# Compares the three ways `Azu::CQL.schema` can serve a PostgreSQL URL, through the same Model calls:
#
#   pg      the pg shard on crystal-db's pool        (build with -Dbench_pg, driver: :db)
#   native  CQL's native driver on crystal-db's pool (no pg shard, driver: :db)
#   engine  CQL's AsyncEngine pool                   (no pg shard, the default)
#
# Run it through scripts/cql_driver_bench.sh (builds both binaries with --release and alternates the drivers).
# Settings (environment): BENCH_OPS (default 5000), BENCH_CONCURRENCY (default 8), BENCH_WARMUP (default 300),
# BENCH_PREPARED=0 turns prepared statements off for every driver. DATABASE_URL (required) must name a local server and a
# database whose name contains "bench" or "test" (BENCH_ALLOW_REMOTE=1 and BENCH_I_KNOW=1 override). It drops and creates
# the table azu_bench_items. All three drivers get the same pool: CONCURRENCY connections, all opened before timing.
{% if flag?(:bench_pg) %}
  require "pg"
{% end %}
require "../src/azu"
require "../src/azu/cql"

# Results go to stdout as TSV: keep log lines (CQL INFO "NOTICE" from DROP TABLE IF EXISTS) out of it
Log.setup(:warn, Log::IOBackend.new(io: STDERR))

BASE_URL    = ENV["DATABASE_URL"]? || abort("set DATABASE_URL")
OPS         = (ENV["BENCH_OPS"]? || "5000").to_i
CONCURRENCY = (ENV["BENCH_CONCURRENCY"]? || "8").to_i
WARMUP      = (ENV["BENCH_WARMUP"]? || "300").to_i
PREPARED    = ENV["BENCH_PREPARED"]? != "0"

def check_target(url : String) : Nil
  uri = URI.parse(url)
  local = uri.host.nil? || uri.host.try(&.empty?) || {"localhost", "127.0.0.1", "::1", "[::1]"}.includes?(uri.host)
  abort "refusing a non-local host (#{uri.host}); set BENCH_ALLOW_REMOTE=1 to allow" unless local || ENV["BENCH_ALLOW_REMOTE"]? == "1"
  database = uri.path.lstrip('/')
  safe = database.includes?("bench") || database.includes?("test")
  abort "refusing database #{database.inspect}: its name must contain \"bench\" or \"test\" (BENCH_I_KNOW=1 overrides)" unless safe || ENV["BENCH_I_KNOW"]? == "1"
end

check_target(BASE_URL)

DRIVER_NAME = ARGV[0]? || abort("usage: cql_driver_bench <pg|native|engine>")
DRIVER      = DRIVER_NAME == "engine" ? :engine : :db
Azu::CONFIG.database.instrument = false # measure the driver, not the dashboard

# The same pool for every driver, written in each one's own terms and opened up front (lazy: false).
def bench_url : String
  pool = CONCURRENCY
  extra = if DRIVER == :engine
            "pool_size=#{pool}&pool_min_size=#{pool}" + (PREPARED ? "" : "&statement_cache_size=0")
          else
            "max_pool_size=#{pool}&initial_pool_size=#{pool}&max_idle_pool_size=#{pool}" + (PREPARED ? "" : "&prepared_statements=false")
          end
  "#{BASE_URL}#{BASE_URL.includes?('?') ? '&' : '?'}#{extra}"
end

Bench = Azu::CQL.schema(:bench, bench_url, lazy: false, driver: DRIVER) do
  table :azu_bench_items do
    primary :id, Int64, auto_increment: true
    text :name
    integer :qty
  end
end

class Item
  include CQL::ActiveRecord::Model(Int64)
  db_context Bench, :azu_bench_items

  property name : String
  property qty : Int32

  def initialize(@name : String, @qty : Int32)
  end
end

Bench.exec("DROP TABLE IF EXISTS azu_bench_items")
Bench.exec("CREATE TABLE azu_bench_items (id bigserial PRIMARY KEY, name text NOT NULL, qty int NOT NULL)")
Bench.exec("INSERT INTO azu_bench_items (name, qty) SELECT 'item ' || g, g FROM generate_series(1, 1000) g")

# Hold CONCURRENCY connections at once so every pool is full before timing.
done = Channel(Nil).new
CONCURRENCY.times { spawn { Bench.with_connection(&.scalar("SELECT pg_sleep(0.05)")); done.send(nil) } }
CONCURRENCY.times { done.receive }

def measure(fibers : Int32, &operation : Int32 ->) : Float64
  WARMUP.times { |step| operation.call(step % 1000 + 1) } # this shape, before timing it
  per_fiber = OPS // fibers
  finished = Channel(Nil).new
  started = Time.instant
  fibers.times do |fiber|
    spawn do
      per_fiber.times { |step| operation.call((fiber * per_fiber + step) % 1000 + 1) }
      finished.send(nil)
    end
  end
  fibers.times { finished.receive }
  (per_fiber * fibers) / (Time.instant - started).total_seconds
end

results = {
  "point query, 1 fiber"                => measure(1) { |id| Item.query.find(id.to_i64) },
  "point query, #{CONCURRENCY} fibers"  => measure(CONCURRENCY) { |id| Item.query.find(id.to_i64) },
  "20-row query, 1 fiber"               => measure(1) { |id| Item.query.where_gt(:qty, id.to_i64).limit(20).all },
  "20-row query, #{CONCURRENCY} fibers" => measure(CONCURRENCY) { |id| Item.query.where_gt(:qty, id.to_i64).limit(20).all },
}
results.each { |workload, per_second| puts "#{DRIVER_NAME}\t#{workload}\t#{per_second.round(0).to_i}" }

Bench.exec("DROP TABLE IF EXISTS azu_bench_items")
Azu::CQL.shutdown
