require "process"
require "uri"

module Azu
  module Database
    # The operations behind `azu db:*`, usable from code or through `Tasks.run(ARGV)` in a
    # small `db/tasks.cr`:
    #
    # ```
    # require "azu"
    # require "azu/database"
    # require "../src/models/*"
    # require "./migrations/*"
    # require "./seeds"
    #
    # exit Azu::Database::Tasks.run(ARGV)
    # ```
    #
    # `crystal run db/tasks.cr -- migrate`, `-- rollback 2`, `-- status`, `-- setup`, `-- reset`,
    # `-- structure:dump`, `-- analyze`, ... (`help` lists them all).
    module Tasks
      extend self

      class Error < Database::Error
      end

      # Connection parameters of a URL, as `pg_dump`/`psql` want them.
      record Target, host : String?, port : Int32?, user : String?, password : String?, database : String, sslmode : String? do
        def cli_args : Array(String)
          args = [] of String
          host.try { |value| args.concat(["-h", value]) }
          port.try { |value| args.concat(["-p", value.to_s]) }
          user.try { |value| args.concat(["-U", value]) }
          args
        end

        def env : Hash(String, String)
          values = {} of String => String
          password.try { |value| values["PGPASSWORD"] = value }
          sslmode.try { |value| values["PGSSLMODE"] = value }
          values
        end
      end

      # Limits migrate/rollback/status to these classes (nil: every registered migration).
      class_property migrations : Array(BaseMigration.class)? = nil

      COMMANDS = {
        "create"         => "Create the database",
        "drop"           => "Drop the database (--force in production)",
        "setup"          => "create + migrate + seed",
        "reset"          => "drop + setup",
        "migrate"        => "Apply pending migrations [VERSION] (--dry-run prints the SQL)",
        "rollback"       => "Revert the last migration [STEPS] (--dry-run)",
        "redo"           => "Revert and re-apply the last migration",
        "status"         => "List migrations and whether they are applied",
        "version"        => "Print the current schema version",
        "seed"           => "Run the seeds registered with Azu::Database.seed",
        "structure:dump" => "Write db/structure.sql with pg_dump [PATH]",
        "structure:load" => "Load db/structure.sql with psql [PATH]",
        "analyze"        => "PostgreSQL health report (--refresh runs ANALYZE)",
      }

      def target(url : String = Database.url) : Target
        uri = URI.parse(url)
        database = uri.path.lstrip('/')
        raise Error.new("the database URL has no database name: #{URLResolver.redact(url)}") if database.empty?
        Target.new(uri.host, uri.port, uri.user, uri.password, database, uri.query_params["sslmode"]?)
      end

      # ---- database lifecycle -----------------------------------------------------------------

      def exists?(url : String = Database.url) : Bool
        name = target(url).database
        with_maintenance(url) { |db| database_exists?(db, name) }
      end

      # Returns false when the database already existed.
      def create(url : String = Database.url) : Bool
        name = target(url).database
        with_maintenance(url) do |db|
          next false if database_exists?(db, name)
          db.exec("CREATE DATABASE #{Migrations::SQL.ident(name)}")
          true
        end
      end

      # Returns false when there was nothing to drop. Other sessions on the database are terminated,
      # so run it before the app opens its own pool (as `reset` does).
      def drop(url : String = Database.url, force : Bool = false) : Bool
        name = target(url).database
        if Azu::CONFIG.env.production? && !force
          raise Error.new("refusing to drop #{name} in production; pass --force if you really mean it")
        end
        with_maintenance(url) do |db|
          next false unless database_exists?(db, name)
          db.exec("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()", name)
          db.exec("DROP DATABASE #{Migrations::SQL.ident(name)}")
          true
        end
      end

      # ---- migrations -------------------------------------------------------------------------

      def migrate(version : Int64? = nil, dry_run : Bool = false, io : IO = STDOUT) : Array(BaseMigration.class)
        migrator = new_migrator
        ran = migrator.migrate(to: version, dry_run: dry_run)
        report(io, migrator, ran, dry_run, "migrated", "Nothing to migrate.")
        ran
      end

      def rollback(steps : Int32 = 1, dry_run : Bool = false, io : IO = STDOUT) : Array(BaseMigration.class)
        migrator = new_migrator
        reverted = migrator.rollback(steps, dry_run: dry_run)
        report(io, migrator, reverted, dry_run, "reverted", "Nothing to roll back.")
        reverted
      end

      def redo(io : IO = STDOUT) : Nil
        migrator = new_migrator
        reverted = migrator.rollback
        ran = migrator.migrate(to: reverted.max_of?(&.version))
        io.puts "Reverted #{reverted.size} and re-applied #{ran.size} migration(s)."
      end

      def status(io : IO = STDOUT) : Array(Azu::Migrator::Status)
        entries = new_migrator.status
        if entries.empty?
          io.puts "No migrations found."
        else
          io.puts "Status  Migration ID    Name"
          io.puts "-" * 60
          entries.each do |entry|
            marker = entry.missing ? "NO FILE" : (entry.applied? ? "up" : "down")
            io.puts "#{marker.ljust(7)} #{entry.version.to_s.ljust(15)} #{entry.name}"
          end
        end
        entries
      end

      def version(io : IO = STDOUT) : Int64
        current = new_migrator.current_version
        io.puts current
        current
      end

      # ---- seeds ------------------------------------------------------------------------------

      def seed(io : IO = STDOUT) : Int32
        count = Database.run_seeds
        io.puts count.zero? ? "No seeds registered (see Azu::Database.seed)." : "Ran #{count} seed block(s)."
        count
      end

      def setup(io : IO = STDOUT) : Nil
        io.puts(create ? "Created database #{target.database}." : "Database #{target.database} already exists.")
        migrate(io: io)
        seed(io)
      end

      def reset(io : IO = STDOUT, force : Bool = false) : Nil
        io.puts(drop(force: force) ? "Dropped database #{target.database}." : "Database #{target.database} did not exist.")
        setup(io)
      end

      # ---- structure.sql ----------------------------------------------------------------------

      # Writes the schema (no data) with `pg_dump`, plus the applied migration versions so a
      # database loaded from the file knows where it stands.
      def structure_dump(path : String = "db/structure.sql", url : String = Database.url, io : IO = STDOUT) : String
        executable!("pg_dump")
        info = target(url)
        args = ["--schema-only", "--no-owner", "--no-privileges", "--no-comments"] + info.cli_args + [info.database]
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("pg_dump", args, env: info.env, output: output, error: error)
        raise Error.new("pg_dump failed: #{error.to_s.strip}") unless status.success?

        migrator = new_migrator
        applied = migrator.status.select(&.applied?)
        table = "public.#{Migrations::SQL.ident(migrator.table_name)}"
        content = String.build do |str|
          str << output
          unless applied.empty?
            str << "\n-- Applied migrations\n"
            applied.each do |entry|
              str << "INSERT INTO " << table << " (version, name) VALUES (" << entry.version << ", " << Migrations::SQL.literal(entry.name) << ") ON CONFLICT DO NOTHING;\n"
            end
          end
        end
        Dir.mkdir_p(File.dirname(path))
        File.write(path, content)
        io.puts "Wrote #{path} (#{applied.size} migration version(s))."
        path
      end

      # Loads a structure file with `psql` (stops at the first error).
      def structure_load(path : String = "db/structure.sql", url : String = Database.url, io : IO = STDOUT) : Nil
        executable!("psql")
        raise Error.new("#{path} does not exist; run structure:dump first") unless File.exists?(path)
        info = target(url)
        args = ["-v", "ON_ERROR_STOP=1", "-q"] + info.cli_args + ["-d", info.database, "-f", path]
        error = IO::Memory.new
        status = Process.run("psql", args, env: info.env, output: Process::Redirect::Close, error: error)
        raise Error.new("psql failed loading #{path}: #{error.to_s.strip}") unless status.success?
        io.puts "Loaded #{path} into #{info.database}."
      end

      # ---- health -----------------------------------------------------------------------------

      def analyze(refresh : Bool = false, io : IO = STDOUT) : Nil
        maintenance = Maintenance.new
        io.puts maintenance.to_text
        if refresh
          maintenance.analyze!
          io.puts "ANALYZE completed."
        end
      end

      # ---- command line -----------------------------------------------------------------------

      # Runs one command; returns the process exit status (0 ok, 1 failure, 2 usage).
      # Debug and info logs (every SQL statement) stay hidden unless `--verbose` is passed;
      # `quiet: false` leaves the logging setup alone (specs).
      def run(args : Array(String), io : IO = STDOUT, err : IO = STDERR, quiet : Bool = true) : Int32
        command = args.first? || "help"
        options = Options.new(args.size > 1 ? args[1..] : [] of String)
        ::Log.setup(:warn) if quiet && !options.flag?("--verbose")

        return 0 if dispatch(command, options, io)
        err.puts "unknown command #{command.inspect}"
        print_usage(err)
        2
      rescue ex : Database::Error | Migrations::MigrationError | Migrations::InvalidIdentifier | ArgumentError
        err.puts "error: #{ex.message}"
        1
      end

      # Flags (`--dry-run`) and positional arguments (`rollback 3`) of one command line.
      private struct Options
        getter positional : Array(String)
        @flags : Array(String)

        def initialize(args : Array(String))
          @flags = args.select(&.starts_with?("--"))
          @positional = args.reject(&.starts_with?("--"))
        end

        def flag?(name : String) : Bool
          @flags.includes?(name)
        end
      end

      # False for an unknown command.
      private def dispatch(command : String, options : Options, io : IO) : Bool
        case command
        when "help", "--help", "-h"                             then print_usage(io)
        when "create", "drop", "setup", "reset"                 then run_lifecycle(command, options, io)
        when "migrate", "rollback", "redo", "status", "version" then run_migrations(command, options, io)
        when "seed"                                             then seed(io)
        when "structure:dump", "structure:load", "analyze"      then run_structure(command, options, io)
        else
          return false
        end
        true
      end

      private def run_lifecycle(command : String, options : Options, io : IO) : Nil
        force = options.flag?("--force")
        case command
        when "create" then io.puts(create ? "Created database #{target.database}." : "Database #{target.database} already exists.")
        when "drop"   then io.puts(drop(force: force) ? "Dropped database #{target.database}." : "Database #{target.database} does not exist.")
        when "setup"  then setup(io)
        else               reset(io, force)
        end
      end

      private def run_migrations(command : String, options : Options, io : IO) : Nil
        argument = options.positional.first?
        dry_run = options.flag?("--dry-run")
        case command
        when "migrate"  then migrate(argument.try { |value| integer!(value, "VERSION") }, dry_run, io)
        when "rollback" then rollback(argument.try { |value| integer!(value, "STEPS").to_i32 } || 1, dry_run, io)
        when "redo"     then redo(io)
        when "status"   then status(io)
        else                 version(io)
        end
      end

      private def run_structure(command : String, options : Options, io : IO) : Nil
        path = options.positional.first? || "db/structure.sql"
        case command
        when "structure:dump" then structure_dump(path, io: io)
        when "structure:load" then structure_load(path, io: io)
        else                       analyze(options.flag?("--refresh"), io)
        end
      end

      def print_usage(io : IO) : Nil
        io.puts "Usage: crystal run db/tasks.cr -- <command> [options]\n\nCommands:"
        width = COMMANDS.keys.max_of(&.size)
        COMMANDS.each { |name, description| io.puts "  #{name.ljust(width)}  #{description}" }
        io.puts "\nAdd --verbose to any command to log the SQL that runs."
      end

      # ---- helpers ----------------------------------------------------------------------------

      private def with_maintenance(url : String, &)
        uri = URI.parse(url)
        uri.path = "/postgres"
        ::DB.open(uri.to_s) { |db| yield db }
      rescue ex : ::DB::ConnectionRefused | ::DB::Error | IO::Error | Socket::Error
        raise Error.new("cannot reach the PostgreSQL server for #{URLResolver.redact(url)}: #{ex.message}")
      end

      private def database_exists?(db : ::DB::Database, name : String) : Bool
        db.scalar("SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", name).as(Bool)
      end

      private def new_migrator : Azu::Migrator
        Azu::Migrator.new(migrations: migrations)
      end

      private def executable!(name : String) : Nil
        Process.find_executable(name) || raise Error.new("#{name} not found on PATH (install the PostgreSQL client tools)")
      end

      private def integer!(value : String, label : String) : Int64
        value.to_i64? || raise ArgumentError.new("#{label} must be a number, got #{value.inspect}")
      end

      private def report(io : IO, migrator : Azu::Migrator, migrations : Array(BaseMigration.class), dry_run : Bool, verb : String, none : String) : Nil
        if migrations.empty?
          io.puts none
          return
        end
        if dry_run
          io.puts "-- dry run: nothing was changed"
          migrator.statements.each { |sql| io.puts "#{sql};" }
        else
          migrations.each { |migration| io.puts "#{verb} #{migration.version} #{migration.migration_name}" }
        end
      end
    end
  end
end
