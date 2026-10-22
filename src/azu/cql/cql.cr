# Opt-in bridge between the CQL ORM and Azu's dev dashboard.
#
#   require "azu"
#   require "azu/cql"
#
#   AppDB = Azu::CQL.schema(:app, "sqlite3://./app.db") do
#     table :users { primary :id, Int64; column :name, String }
#   end
#
# Every query, transaction and the connection pool then show up in the
# dashboard's "Database & Queries" tab, tagged with the HTTP request that ran them.
require "cql"
require "../query_store"
require "../request_context"
require "./instrumentor"
require "./adapter"

module Azu
  module CQL
    # Defines a schema, picking the CQL adapter from the URI scheme (falls back to
    # `Azu::CONFIG.database.uri`), and wires instrumentation and the playground to it.
    def self.schema(name : Symbol = :app, uri : String? = nil, &) : ::CQL::Schema
      resolved = uri || Azu::CONFIG.database.uri || raise ArgumentError.new("Azu::CQL.schema needs a uri or Azu.configure { |c| c.database.uri = ... }")
      Instrumentor.install
      schema = ::CQL::Schema.new(name, resolved, adapter_for(resolved))
      with schema yield
      attach(schema)
    end

    # Wires instrumentation and the dashboard playground to an existing schema.
    def self.attach(schema : ::CQL::Schema) : ::CQL::Schema
      Instrumentor.install
      QueryStore.instance.adapter = SchemaAdapter.new(schema)
      schema
    end

    # Runs the block in a database transaction (rolled back on exception); the
    # queries inside are visible as one transaction in the dashboard.
    def self.transaction(schema : ::CQL::Schema, &)
      schema.transaction { |_tx| yield }
    end

    def self.adapter_for(uri : String) : ::CQL::Adapter
      case URI.parse(uri).scheme
      when "postgres", "postgresql" then ::CQL::Adapter::Postgres
      else                               ::CQL::Adapter::SQLite
      end
    end

    # Apps usually `include Azu`, which makes this module visible as `CQL` inside
    # their namespace, and CQL's own macros expand unqualified `CQL::...` there.
    # Mirror every ORM type here so `CQL::ActiveRecord::Model` keeps resolving.
    {% for name in ::CQL.constants %}
      {% type = ::CQL.constant(name) %}
      {% if type.is_a?(TypeNode) && !Azu::CQL.has_constant?(name) %}
        alias {{ name.id }} = ::CQL::{{ name.id }}
      {% end %}
    {% end %}
  end
end
