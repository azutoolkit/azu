module Azu
  # Zero-boilerplate database access for Azu apps.
  #
  # ```
  # require "azu/database"
  # Azu.configure { |c| c.database.url = ENV["DATABASE_URL"] } # optional
  # ```
  #
  # The connection pool is opened lazily on first use (or on `Azu.start`), the
  # schema is populated from the `Azu::Model` classes, and instrumentation for
  # the dev dashboard is installed automatically.
  module Database
    @@mutex = Mutex.new
    @@schema : ::CQL::Schema? = nil
    @@pending_check : Proc(Int32)? = nil

    def self.config : DatabaseConfiguration
      Azu::CONFIG.database
    end

    # Connection URL after applying configuration, environment and conventions.
    def self.url : String
      URLResolver.resolve(config, Azu::CONFIG.env, URLResolver.app_slug(PROGRAM_NAME))
    end

    # True when the app opted into a database (a model exists or a URL is configured).
    def self.configured? : Bool
      Registry.any? || !config.url.nil? || !ENV["DATABASE_URL"]?.nil?
    end

    def self.connected? : Bool
      !@@schema.nil?
    end

    # The shared CQL schema (connects on first call, thread-safe).
    def self.schema : ::CQL::Schema
      @@schema || @@mutex.synchronize { @@schema ||= connect }
    end

    # Replaces the schema (tests, multiple environments). Closes nothing.
    def self.schema=(schema : ::CQL::Schema?)
      @@mutex.synchronize { @@schema = schema }
    end

    # Opens the pool, installs instrumentation and verifies connectivity.
    def self.boot : Nil
      return unless configured?
      schema
      ping!
      Azu::CONFIG.log.info { "Database connected: #{URLResolver.redact(url)}" }
      warn_pending_migrations
    end

    # True if `SELECT 1` succeeds. Never raises, usable in health endpoints.
    def self.healthy? : Bool
      ping!
      true
    rescue
      false
    end

    def self.ping! : Nil
      schema.raw_readonly("SELECT 1", 1)
    rescue ex : ConnectionError
      raise ex
    rescue ex
      raise ConnectionError.new(connection_help(ex))
    end

    # Pool counters, or nil before the first connection.
    def self.pool : PoolSnapshot?
      return unless connected?
      stats = schema.pool_stats
      PoolSnapshot.new(stats.open, stats.idle, stats.in_flight, stats.max)
    end

    # Set by `Azu::Migrator`: returns how many migrations are pending.
    def self.pending_check=(check : Proc(Int32)?)
      @@pending_check = check
    end

    private def self.connect : ::CQL::Schema
      resolved = url
      schema = begin
        ::CQL::Schema.new(:azu, resolved, Azu::CQL.adapter_for(resolved))
      rescue ex
        raise ConnectionError.new(connection_help(ex))
      end
      Registry.apply_all(schema)
      Registry.listener = ->(table : Symbol) { sync_table(table) }
      Azu::CQL.attach(schema) if config.instrument?
      schema
    end

    private def self.sync_table(table : Symbol) : Nil
      if current = @@schema
        Registry.apply(current, table)
      end
    end

    private def self.warn_pending_migrations : Nil
      return unless Azu::CONFIG.env.development?
      return unless check = @@pending_check
      pending = check.call
      Azu::CONFIG.log.warn { "#{pending} pending migration(s): run `azu db:migrate`" } if pending > 0
    rescue
      nil
    end

    private def self.connection_help(ex : Exception) : String
      <<-MSG
      Cannot connect to the database (#{URLResolver.redact(url)}): #{ex.message}
        - Is PostgreSQL running and reachable?
        - Create the database with `azu db:create` (or `createdb`).
        - Point Azu at it with DATABASE_URL or `Azu.configure { |c| c.database.url = "postgres://..." }`.
      MSG
    end
  end
end

Azu.on_boot { Azu::Database.boot }
