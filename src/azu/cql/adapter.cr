module Azu
  module CQL
    # Gives the dashboard read-only SQL access and pool stats for a CQL schema.
    class SchemaAdapter < DatabaseAdapter
      def initialize(@schema : ::CQL::Schema)
      end

      def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
        @schema.raw_readonly(sql, limit)
      end

      def pool : PoolSnapshot?
        stats = @schema.pool_stats
        PoolSnapshot.new(stats.open, stats.idle, stats.in_flight, stats.max)
      rescue
        nil
      end

      def dialect : String
        case @schema.adapter
        when ::CQL::Adapter::Postgres then "postgres"
        when ::CQL::Adapter::MySql    then "mysql"
        else                               "sqlite"
        end
      end
    end
  end
end
