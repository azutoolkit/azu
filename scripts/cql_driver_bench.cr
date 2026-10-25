# Compares the three ways `Azu::CQL.schema` can serve a PostgreSQL URL, through the same Model calls:
#
#   pg      the pg shard on crystal-db's pool        (build with -Dbench_pg, driver: :db)
#   native  CQL's native driver on crystal-db's pool (no pg shard, driver: :db)
#   engine  CQL's AsyncEngine pool                   (no pg shard, the default)
#
# Run it through scripts/cql_driver_bench.sh (builds both binaries with --release and alternates the drivers).
# Settings (environment): BENCH_OPS (default 5000), BENCH_CONCURRENCY (default 8), BENCH_WARMUP (default 300),
# DATABASE_URL (required). It drops and creates the table azu_bench_items.
{% if flag?(:bench_pg) %}
  require "pg"
{% end %}
require "../src/azu"
require "../src/azu/cql"

URL         = ENV["DATABASE_URL"]? || abort("set DATABASE_URL")
OPS         = (ENV["BENCH_OPS"]? || "5000").to_i
CONCURRENCY = (ENV["BENCH_CONCURRENCY"]? || "8").to_i
WARMUP      = (ENV["BENCH_WARMUP"]? || "300").to_i

DRIVER_NAME = ARGV[0]? || abort("usage: cql_driver_bench <pg|native|engine>")
DRIVER      = DRIVER_NAME == "engine" ? :engine : :db
Azu::CONFIG.database.instrument = false # measure the driver, not the dashboard

Bench = Azu::CQL.schema(:bench, URL, driver: DRIVER) do
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

WARMUP.times { |step| Item.query.find(step % 1000 + 1) }

results = {
  "point query, 1 fiber"                => measure(1) { |id| Item.query.find(id.to_i64) },
  "point query, #{CONCURRENCY} fibers"  => measure(CONCURRENCY) { |id| Item.query.find(id.to_i64) },
  "20-row query, 1 fiber"               => measure(1) { |id| Item.query.where_gt(:qty, id.to_i64).limit(20).all },
  "20-row query, #{CONCURRENCY} fibers" => measure(CONCURRENCY) { |id| Item.query.where_gt(:qty, id.to_i64).limit(20).all },
}
results.each { |workload, per_second| puts "#{DRIVER_NAME}\t#{workload}\t#{per_second.round(0).to_i}" }

Bench.exec("DROP TABLE IF EXISTS azu_bench_items")
Azu::CQL.shutdown
