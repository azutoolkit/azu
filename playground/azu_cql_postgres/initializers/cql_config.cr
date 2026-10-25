# The only Azu <-> CQL wiring an app needs: configure CQL, attach the dashboard.
#
# Initializers load before db/schema.cr, so the schema is attached lazily: the dashboard
# resolves AppDB the first time it needs it. Everything after this (schema, models, queries,
# transactions, migrations) is plain CQL.
# No `require "pg"`: postgres:// URLs run on CQL's native engine pool (driver: :db brings the pg shard back).
require "../../../src/azu/cql" # in an app: require "azu/cql"

Azu::CQL.configure do |c|
  # DATABASE_URL, e.g. postgres://postgres@localhost:5432/azu_cql_demo
  c.db = ENV["DATABASE_URL"]? || "postgres://localhost/azu_cql_demo"
  c.pool.size = 10
end

Azu::CQL.attach { AppDB }
