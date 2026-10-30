module Azu
  module CQL
    # Gives the dashboard read-only SQL access and pool stats for a CQL schema.
    #
    # The schema may be given later as a block (`Azu::CQL.attach { AppDB }`): it is resolved the
    # first time the dashboard needs it. A schema that cannot be resolved or reached never breaks
    # the Database tab: the pool card is empty and the playground reports the error.
    class SchemaAdapter < DatabaseAdapter
      @schema : ::CQL::Schema?
      @provider : Proc(::CQL::Schema)?
      @mutex = Mutex.new

      def initialize(@schema : ::CQL::Schema)
        @provider = nil
      end

      def initialize(@provider : Proc(::CQL::Schema))
        @schema = nil
      end

      # Runs one statement in a transaction that is always rolled back and returns
      # `{column_names, rows}` with at most `limit` rows (values as text, `nil` stays `nil`).
      # The caller validates the SQL (`QueryAnalysis.playground_sql`).
      def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
        columns = [] of String
        rows = [] of Array(String?)
        schema.with_connection do |connection|
          connection.transaction do |transaction|
            transaction.connection.query(sql) do |result|
              columns = result.column_names
              while rows.size < limit && result.move_next
                rows << Array(String?).new(columns.size) { text(result.read) }
              end
            end
            raise DB::Rollback.new
          end
        end
        {columns, rows}
      end

      def schema_snapshot : JSON::Any?
        JSON.parse({tables: schema.tables.first(100).map do |name, table|
          {name: name.to_s, columns: table.columns.first(100).map { |column, definition| {name: column.to_s, type: definition.type.to_s} }}
        end}.to_json)
      rescue
        nil
      end

      def pool : PoolSnapshot?
        stats = schema.pool_stats
        PoolSnapshot.new(stats.open, stats.idle, stats.in_flight, stats.max)
      rescue
        nil
      end

      def dialect : String
        case schema.adapter
        when .postgres_compatible? then "postgres" # PostgreSQL and CockroachDB share EXPLAIN
        when .my_sql?              then "mysql"
        else                            "sqlite"
        end
      rescue
        "unknown" # plain EXPLAIN; the statement itself will report why the schema is unavailable
      end

      def adapter_name : String?
        schema.adapter.to_s
      rescue
        nil
      end

      # Which connection layer serves the schema: crystal-db's pool, CQL's native PostgreSQL engine, or another source.
      def connection_source : String?
        {% if ::CQL.has_constant?("ConnectionSource") %}
          source = schema.source
          {% if ::CQL.has_constant?("Postgres") && ::CQL::Postgres.has_constant?("EngineSource") %}
            return "native PostgreSQL engine" if source.is_a?(::CQL::Postgres::EngineSource)
          {% end %}
          source.is_a?(::CQL::DatabaseSource) ? "crystal-db pool" : source.class.name
        {% else %}
          "crystal-db pool"
        {% end %}
      rescue
        nil
      end

      private def schema : ::CQL::Schema
        @schema || @mutex.synchronize { @schema ||= @provider.not_nil!.call }
      end

      private def text(value) : String?
        case value
        when Nil   then nil
        when Bytes then "<#{value.size} bytes>"
        else            value.to_s
        end
      end
    end
  end
end
