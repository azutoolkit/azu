module Azu
  # Applies and reverts `Azu::Migration` classes and records them in `schema_migrations`.
  #
  # ```
  # migrator = Azu::Migrator.new
  # migrator.migrate # everything pending
  # migrator.migrate(to: 20261022000001_i64)
  # migrator.rollback # last migration
  # migrator.rollback(3)
  # migrator.status.each { |s| puts "#{s.applied? ? "up  " : "down"} #{s.version} #{s.name}" }
  # ```
  #
  # * One migration at a time, each in its own transaction unless it calls `disable_ddl_transaction!`.
  # * A session advisory lock serialises concurrent runs (several app instances booting at once).
  # * `dry_run: true` collects the SQL (`#statements`) without touching the database.
  class Migrator
    # Arbitrary constant naming the advisory lock ("azu migrations").
    LOCK_KEY = 7_281_904_551_203_i64

    record Status, version : Int64, name : String, applied_at : Time?, missing : Bool = false do
      def applied? : Bool
        !applied_at.nil?
      end
    end

    @@migrations = [] of BaseMigration.class
    @@mutex = Mutex.new

    # Called by `Azu::Migration(V)` when a subclass is defined.
    def self.register(migration : BaseMigration.class) : Nil
      @@mutex.synchronize { @@migrations << migration unless @@migrations.includes?(migration) }
    end

    # Registered migrations ordered by version; two classes with one version is an error.
    def self.migrations : Array(BaseMigration.class)
      sorted = @@mutex.synchronize { @@migrations.sort_by(&.version) }
      sorted.each_cons_pair do |first, second|
        raise Migrations::MigrationError.new("duplicate migration version #{first.version}: #{first.migration_name} and #{second.migration_name}") if first.version == second.version
      end
      sorted
    end

    # Forgets every registered migration (specs).
    def self.clear : Nil
      @@mutex.synchronize { @@migrations.clear }
    end

    getter schema : ::CQL::Schema
    getter table_name : String
    # SQL collected by the last run (always filled; only executed when not a dry run).
    getter statements = [] of String

    def initialize(@schema : ::CQL::Schema = Azu::Database.schema, table : Symbol | String = :schema_migrations)
      @table_name = table.to_s
      @table = Migrations::SQL.ident(table)
    end

    # Applies pending migrations (up to `to`, inclusive). Returns the ones that ran.
    def migrate(to : Int64? = nil, dry_run : Bool = false) : Array(BaseMigration.class)
      @statements.clear
      ran = [] of BaseMigration.class
      with_connection(dry_run) do |conn|
        applied = applied_versions(conn)
        todo = self.class.migrations.reject { |migration| applied.includes?(migration.version) }
        todo = todo.select { |migration| migration.version <= to } if to
        todo.each do |migration|
          run(migration, :up, conn, dry_run)
          ran << migration
        end
      end
      ran
    end

    # Reverts the last `steps` applied migrations, newest first.
    def rollback(steps : Int32 = 1, dry_run : Bool = false) : Array(BaseMigration.class)
      revert(dry_run) { |versions| versions.first(steps) }
    end

    # Reverts everything newer than `version` (use 0 to revert all).
    def rollback_to(version : Int64, dry_run : Bool = false) : Array(BaseMigration.class)
      revert(dry_run) { |versions| versions.select { |applied| applied > version } }
    end

    # Reverts and re-applies the last migration.
    def redo : Array(BaseMigration.class)
      reverted = rollback
      migrate(to: reverted.map(&.version).max?)
    end

    def status : Array(Status)
      applied = {} of Int64 => {String, Time}
      @schema.exec_query do |conn|
        if table_exists?(conn)
          conn.query_each("SELECT version, name, applied_at FROM #{@table}") do |rs|
            version, name, at = rs.read(Int64, String, Time)
            applied[version] = {name, at}
          end
        end
      end

      known = self.class.migrations.map do |migration|
        Status.new(migration.version, migration.migration_name, applied[migration.version]?.try(&.[1]))
      end
      orphans = applied.reject { |version, _| known.any? { |status| status.version == version } }.map do |version, (name, at)|
        Status.new(version, name, at, missing: true)
      end
      (known + orphans).sort_by(&.version)
    end

    def pending : Array(BaseMigration.class)
      applied = applied_versions
      self.class.migrations.reject { |migration| applied.includes?(migration.version) }
    end

    def pending_count : Int32
      pending.size
    end

    def current_version : Int64
      applied_versions.max? || 0_i64
    end

    def applied_versions : Set(Int64)
      @schema.exec_query { |conn| applied_versions(conn) }
    end

    private def applied_versions(conn : ::DB::Connection) : Set(Int64)
      return Set(Int64).new unless table_exists?(conn)
      conn.query_all("SELECT version FROM #{@table}", as: Int64).to_set
    end

    private def table_exists?(conn : ::DB::Connection) : Bool
      conn.scalar("SELECT to_regclass($1) IS NOT NULL", @table_name).as(Bool)
    end

    private def revert(dry_run : Bool, & : Array(Int64) -> Array(Int64)) : Array(BaseMigration.class)
      @statements.clear
      reverted = [] of BaseMigration.class
      with_connection(dry_run) do |conn|
        applied = applied_versions(conn).to_a.sort.reverse!
        yield(applied).each do |version|
          migration = self.class.migrations.find { |candidate| candidate.version == version } ||
                      raise Migrations::MigrationError.new("version #{version} is recorded in #{@table_name} but no migration class defines it")
          run(migration, :down, conn, dry_run)
          reverted << migration
        end
      end
      reverted
    end

    # Holds one connection for the whole run: the advisory lock is per session.
    private def with_connection(dry_run : Bool, &)
      @schema.exec_query do |conn|
        unless dry_run
          conn.exec("SELECT pg_advisory_lock($1)", LOCK_KEY)
          conn.exec("CREATE TABLE IF NOT EXISTS #{@table} (version BIGINT PRIMARY KEY, name TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())")
        end
        begin
          yield conn
        ensure
          conn.exec("SELECT pg_advisory_unlock($1)", LOCK_KEY) unless dry_run
        end
      end
    end

    private def run(migration : BaseMigration.class, direction : Symbol, conn : ::DB::Connection, dry_run : Bool) : Nil
      executor = Migrations::Executor.new(conn, dry_run)
      instance = migration.new(executor)
      label = "#{migration.version} #{migration.migration_name}"
      verb = direction == :up ? "migrating" : "reverting"
      Azu::CONFIG.log.info { "== #{label}: #{verb}" }
      started = Time.instant

      apply = -> do
        if direction == :up
          instance.up
          executor.exec("INSERT INTO #{@table} (version, name) VALUES (#{migration.version}, #{Migrations::SQL.literal(migration.migration_name)})")
        else
          instance.down
          executor.exec("DELETE FROM #{@table} WHERE version = #{migration.version}")
        end
      end

      if migration.ddl_transaction? && !dry_run
        conn.transaction do |tx|
          executor.connection = tx.connection
          executor.in_transaction = true
          apply.call
        end
      else
        apply.call
      end
      @statements.concat(executor.statements)
      Azu::CONFIG.log.info { "== #{label}: done (#{(Time.instant - started).total_milliseconds.round(1)}ms)" }
    rescue ex : Migrations::MigrationError
      raise ex
    rescue ex
      raise Migrations::MigrationError.new("Migration #{migration.version} #{migration.migration_name} failed: #{ex.message}", cause: ex)
    end
  end
end
