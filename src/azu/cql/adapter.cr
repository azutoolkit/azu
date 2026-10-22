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

      def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
        schema.raw_readonly(sql, limit)
      end

      def pool : PoolSnapshot?
        stats = schema.pool_stats
        PoolSnapshot.new(stats.open, stats.idle, stats.in_flight, stats.max)
      rescue
        nil
      end

      def dialect : String
        case schema.adapter
        when ::CQL::Adapter::Postgres then "postgres"
        when ::CQL::Adapter::MySql    then "mysql"
        else                               "sqlite"
        end
      rescue
        "unknown" # plain EXPLAIN; the statement itself will report why the schema is unavailable
      end

      private def schema : ::CQL::Schema
        @schema || @mutex.synchronize { @schema ||= @provider.not_nil!.call }
      end
    end
  end
end
