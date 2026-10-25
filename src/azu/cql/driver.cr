module Azu
  module CQL
    # Which connection layer a schema uses.
    #
    # - `Engine`: CQL's native PostgreSQL `AsyncEngine` pool (`CQL::Postgres::EngineSource`).
    # - `Db`: crystal-db's pool with whichever driver is registered for the URL (the `pg` shard if it is
    #   required, otherwise CQL's native driver). This is also what SQLite and MySQL always use.
    #
    # Chosen per schema, in this order: the `driver:` argument of `Azu::CQL.schema`, the `AZU_CQL_DRIVER`
    # environment variable (`Azu::CONFIG.database.driver`; `engine` or `db`, `pg` is accepted as `db`), then the
    # default: `Engine` for `postgres://` and `postgresql://` when the installed CQL provides it, `Db` otherwise.
    # `cockroachdb://` is `Db` unless `Engine` is asked for. The environment variable is global, so it is ignored for URLs
    # the engine cannot serve; the argument is not (`driver: :engine` on a MySQL URL raises `ArgumentError`).
    module Driver
      enum Kind
        Engine
        Db
      end

      Engine = Kind::Engine
      Db     = Kind::Db

      ENGINE_SCHEMES   = %w(postgres postgresql)
      OPT_IN_SCHEMES   = %w(cockroachdb)
      ENGINE_AVAILABLE = {{ ::CQL.has_constant?("ConnectionSource") && ::CQL.has_constant?("Postgres") && ::CQL::Postgres.has_constant?("EngineSource") }}

      def self.resolve(uri : String, requested : Symbol? = nil, from_env : String? = nil) : Kind
        scheme = URI.parse(uri).scheme.to_s
        if requested
          explicit(from_name(requested.to_s), scheme)
        elsif (named = from_env.presence) && (parsed = from_name(named))
          parsed.engine? && !serves?(scheme) ? Db : available(parsed)
        else
          ENGINE_SCHEMES.includes?(scheme) && ENGINE_AVAILABLE ? Engine : Db
        end
      end

      def self.from_name(name : String) : Kind
        case name.downcase
        when "engine"   then Engine
        when "db", "pg" then Db
        else                 raise ArgumentError.new("unknown CQL driver #{name.inspect}; use :engine or :db (AZU_CQL_DRIVER=engine|db)")
        end
      end

      # What the engine can serve at all (PostgreSQL, and CockroachDB on request).
      def self.serves?(scheme : String) : Bool
        ENGINE_SCHEMES.includes?(scheme) || OPT_IN_SCHEMES.includes?(scheme)
      end

      private def self.explicit(driver : Kind, scheme : String) : Kind
        return driver unless driver.engine?
        raise ArgumentError.new("driver: :engine serves postgres://, postgresql:// and cockroachdb:// URLs, not #{scheme}://") unless serves?(scheme)
        raise ArgumentError.new("driver: :engine needs a CQL release with CQL::Postgres::EngineSource; update the cql shard") unless ENGINE_AVAILABLE
        driver
      end

      private def self.available(driver : Kind) : Kind
        driver.engine? && !ENGINE_AVAILABLE ? Db : driver
      end
    end
  end
end
