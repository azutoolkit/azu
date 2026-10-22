module Azu
  # Base of every migration class (see `Azu::Migration(V)`).
  abstract class BaseMigration
    @executor : ::Azu::Migrations::Executor

    def initialize(@executor : ::Azu::Migrations::Executor)
    end

    abstract def up
    abstract def down

    def self.version : Int64
      0_i64
    end

    def self.migration_name : String
      name
    end

    # False for migrations that opted out with `disable_ddl_transaction!`.
    def self.ddl_transaction? : Bool
      true
    end

    # Runs the migration in a transaction by default; call this in the class body for statements
    # PostgreSQL refuses inside one (`add_index ..., concurrent: true`, `ALTER TYPE ... ADD VALUE` on old servers).
    macro disable_ddl_transaction!
      def self.ddl_transaction? : Bool
        false
      end
    end

    # ---- tables -------------------------------------------------------------------------------

    def create_table(name : Symbol | String, id : Symbol | Bool = :bigserial, if_not_exists : Bool = false, &)
      builder = ::Azu::Migrations::TableBuilder.new(name, id)
      yield builder
      builder.statements(if_not_exists).each { |sql| execute(sql) }
    end

    def drop_table(name : Symbol | String, if_exists : Bool = true, cascade : Bool = false) : Nil
      execute "DROP TABLE #{"IF EXISTS " if if_exists}#{::Azu::Migrations::SQL.ident(name)}#{" CASCADE" if cascade}"
    end

    def rename_table(from : Symbol | String, to : Symbol | String) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(from)} RENAME TO #{::Azu::Migrations::SQL.ident(to)}"
    end

    # ---- columns ------------------------------------------------------------------------------

    def add_column(table : Symbol | String, name : Symbol | String, type : Symbol | String, null : Bool = false, default : ::Azu::Migrations::Literal = nil,
                   default_sql : String? = nil, unique : Bool = false, check : String? = nil, limit : Int32? = nil, precision : Int32? = nil,
                   scale : Int32? = nil, array : Bool = false, if_not_exists : Bool = false) : Nil
      definition = Migrations.column_sql(name, type, null, default, default_sql, unique, check, limit, precision, scale, array)
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} ADD COLUMN #{"IF NOT EXISTS " if if_not_exists}#{definition}"
    end

    def remove_column(table : Symbol | String, name : Symbol | String, if_exists : Bool = true) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} DROP COLUMN #{"IF EXISTS " if if_exists}#{::Azu::Migrations::SQL.ident(name)}"
    end

    def rename_column(table : Symbol | String, from : Symbol | String, to : Symbol | String) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} RENAME COLUMN #{::Azu::Migrations::SQL.ident(from)} TO #{::Azu::Migrations::SQL.ident(to)}"
    end

    def change_column_null(table : Symbol | String, column : Symbol | String, null : Bool) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} ALTER COLUMN #{::Azu::Migrations::SQL.ident(column)} #{null ? "DROP" : "SET"} NOT NULL"
    end

    def change_column_default(table : Symbol | String, column : Symbol | String, default : ::Azu::Migrations::Literal = nil, default_sql : String? = nil) : Nil
      target = "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} ALTER COLUMN #{::Azu::Migrations::SQL.ident(column)}"
      if default_sql
        execute "#{target} SET DEFAULT #{default_sql}"
      elsif default.nil?
        execute "#{target} DROP DEFAULT"
      else
        execute "#{target} SET DEFAULT #{::Azu::Migrations::SQL.literal(default)}"
      end
    end

    # `using:` is the conversion expression PostgreSQL needs between incompatible types (`"id::text"`).
    def change_column_type(table : Symbol | String, column : Symbol | String, type : Symbol | String, using : String? = nil, limit : Int32? = nil,
                           array : Bool = false) : Nil
      sql = "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} ALTER COLUMN #{::Azu::Migrations::SQL.ident(column)} TYPE #{Migrations.sql_type(type, limit, nil, nil, array)}"
      execute(using ? "#{sql} USING #{using}" : sql)
    end

    # ---- indexes ------------------------------------------------------------------------------

    # `concurrent: true` builds the index without blocking writes; it needs `disable_ddl_transaction!`.
    def add_index(table : Symbol | String, columns : Symbol | String | Array(Symbol | String), unique : Bool = false, name : String? = nil,
                  using : Symbol | String | Nil = nil, where : String? = nil, covering : Array(Symbol | String)? = nil, opclass : String? = nil,
                  expression : String? = nil, concurrent : Bool = false, if_not_exists : Bool = false) : Nil
      @executor.require_no_transaction!("CREATE INDEX CONCURRENTLY") if concurrent
      list = columns.is_a?(Array) ? columns : [columns.as(Symbol | String)]
      execute ::Azu::Migrations::SQL.create_index(table, list, unique, name, using, where, covering, expression, opclass, concurrent, if_not_exists)
    end

    # Drops by the name `add_index` generated (`index_<table>_on_<columns>`) or an explicit `name:`.
    def remove_index(table : Symbol | String, columns : Symbol | String | Array(Symbol | String) | Nil = nil, name : String? = nil,
                     concurrent : Bool = false, if_exists : Bool = true) : Nil
      @executor.require_no_transaction!("DROP INDEX CONCURRENTLY") if concurrent
      names = columns.nil? ? ["expr"] : (columns.is_a?(Array) ? columns : [columns.as(Symbol | String)]).map(&.to_s)
      execute ::Azu::Migrations::SQL.drop_index(::Azu::Migrations::SQL.index_name(table, names, name), concurrent, if_exists)
    end

    # ---- constraints --------------------------------------------------------------------------

    # `validate: false` adds the key as NOT VALID (no table scan, no long lock); finish with `validate_foreign_key`.
    def add_foreign_key(from_table : Symbol | String, to_table : Symbol | String, column : Symbol | String | Nil = nil, primary_key : String = "id",
                        name : String? = nil, on_delete : Symbol | String | Nil = nil, on_update : Symbol | String | Nil = nil, validate : Bool = true) : Nil
      fk_column = (column || "#{to_table.to_s.rchop('s')}_id").to_s
      constraint = name || "fk_#{from_table}_#{fk_column}"
      sql = String.build do |io|
        io << "ALTER TABLE " << ::Azu::Migrations::SQL.ident(from_table) << " ADD CONSTRAINT " << ::Azu::Migrations::SQL.ident(constraint)
        io << " FOREIGN KEY (" << ::Azu::Migrations::SQL.ident(fk_column) << ") REFERENCES " << ::Azu::Migrations::SQL.ident(to_table) << " (" << ::Azu::Migrations::SQL.ident(primary_key) << ')'
        io << " ON DELETE " << ::Azu::Migrations::SQL.action(on_delete) if on_delete
        io << " ON UPDATE " << ::Azu::Migrations::SQL.action(on_update) if on_update
        io << " NOT VALID" unless validate
      end
      execute sql
    end

    def validate_foreign_key(table : Symbol | String, name : String) : Nil
      validate_constraint(table, name)
    end

    def remove_foreign_key(table : Symbol | String, name : String, if_exists : Bool = true) : Nil
      drop_constraint(table, name, if_exists)
    end

    def add_check_constraint(table : Symbol | String, expression : String, name : String, validate : Bool = true) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} ADD CONSTRAINT #{::Azu::Migrations::SQL.ident(name)} CHECK (#{expression})#{" NOT VALID" unless validate}"
    end

    def validate_check_constraint(table : Symbol | String, name : String) : Nil
      validate_constraint(table, name)
    end

    def remove_check_constraint(table : Symbol | String, name : String, if_exists : Bool = true) : Nil
      drop_constraint(table, name, if_exists)
    end

    # ---- PostgreSQL types and extensions ------------------------------------------------------

    def create_enum(name : Symbol | String, values : Array(String)) : Nil
      raise ArgumentError.new("an enum needs at least one value") if values.empty?
      execute "CREATE TYPE #{::Azu::Migrations::SQL.ident(name)} AS ENUM (#{values.map { |value| ::Azu::Migrations::SQL.literal(value) }.join(", ")})"
    end

    def drop_enum(name : Symbol | String, if_exists : Bool = true) : Nil
      execute "DROP TYPE #{"IF EXISTS " if if_exists}#{::Azu::Migrations::SQL.ident(name)}"
    end

    def add_enum_value(name : Symbol | String, value : String, if_not_exists : Bool = true) : Nil
      execute "ALTER TYPE #{::Azu::Migrations::SQL.ident(name)} ADD VALUE #{"IF NOT EXISTS " if if_not_exists}#{::Azu::Migrations::SQL.literal(value)}"
    end

    def enable_extension(name : Symbol | String) : Nil
      execute "CREATE EXTENSION IF NOT EXISTS #{::Azu::Migrations::SQL.ident(name)}"
    end

    def disable_extension(name : Symbol | String) : Nil
      execute "DROP EXTENSION IF EXISTS #{::Azu::Migrations::SQL.ident(name)}"
    end

    # ---- escape hatch -------------------------------------------------------------------------

    # Raw SQL for anything the DSL does not cover.
    def execute(sql : String) : Nil
      @executor.exec(sql)
    end

    private def validate_constraint(table : Symbol | String, name : String) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} VALIDATE CONSTRAINT #{::Azu::Migrations::SQL.ident(name)}"
    end

    private def drop_constraint(table : Symbol | String, name : String, if_exists : Bool) : Nil
      execute "ALTER TABLE #{::Azu::Migrations::SQL.ident(table)} DROP CONSTRAINT #{"IF EXISTS " if if_exists}#{::Azu::Migrations::SQL.ident(name)}"
    end
  end

  # A migration. The type argument is the version (a timestamp, `YYYYMMDDHHMMSS`).
  #
  # ```
  # class CreateUsers < Azu::Migration(20261022000001_i64)
  #   def up
  #     create_table :users do |t|
  #       t.string :email
  #       t.timestamps
  #       t.index :email, unique: true
  #     end
  #   end
  #
  #   def down
  #     drop_table :users
  #   end
  # end
  # ```
  abstract class Migration(V) < BaseMigration
    macro inherited
      ::Azu::Migrator.register({{@type}})

      def self.version : Int64
        V.to_i64
      end

      def self.migration_name : String
        {{@type.name.stringify}}
      end
    end
  end
end
