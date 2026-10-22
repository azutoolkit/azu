module Azu
  module Migrations
    class MigrationError < Exception
    end

    # Runs (or, in a dry run, only collects) the SQL a migration generates.
    class Executor
      getter statements = [] of String
      getter? dry_run : Bool
      # True while the migration runs inside BEGIN/COMMIT. Statements that PostgreSQL
      # refuses in a transaction (CREATE INDEX CONCURRENTLY) check this first.
      property? in_transaction : Bool = false

      def initialize(@connection : ::DB::Connection?, @dry_run : Bool = false, @log : ::Log = Azu::CONFIG.log)
      end

      def exec(sql : String) : Nil
        @log.debug { sql }
        @statements << sql
        return if @dry_run
        connection.exec(sql)
      end

      # Raises unless the migration opted out of the DDL transaction with `disable_ddl_transaction!`.
      def require_no_transaction!(statement : String) : Nil
        return unless in_transaction?
        raise MigrationError.new("#{statement} cannot run inside a transaction. Add `disable_ddl_transaction!` to the migration class.")
      end

      def connection : ::DB::Connection
        @connection || raise MigrationError.new("no database connection (dry run?)")
      end

      def connection=(connection : ::DB::Connection) : Nil
        @connection = connection
      end
    end
  end
end
