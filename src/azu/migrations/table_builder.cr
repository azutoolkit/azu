module Azu
  module Migrations
    alias Literal = Nil | String | Int32 | Int64 | Float64 | Bool | Symbol | Time | JSON::Any

    # SQL types for the symbols the DSL accepts (`t.column :x, :jsonb`, `add_column ... :text`).
    TYPES = {
      string:    "character varying(255)",
      text:      "text",
      integer:   "integer",
      smallint:  "smallint",
      bigint:    "bigint",
      float:     "double precision",
      decimal:   "numeric",
      boolean:   "boolean",
      date:      "date",
      time:      "time",
      datetime:  "timestamptz",
      timestamp: "timestamptz",
      uuid:      "uuid",
      json:      "json",
      jsonb:     "jsonb",
      binary:    "bytea",
      inet:      "inet",
      citext:    "citext",
      hstore:    "hstore",
    }

    # Builds a column definition shared by `create_table` and `add_column`.
    def self.column_sql(name : Symbol | String, type : Symbol | String, null : Bool = false, default : Literal = nil, default_sql : String? = nil,
                        unique : Bool = false, check : String? = nil, limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil,
                        array : Bool = false, primary_key : Bool = false) : String
      String.build do |io|
        io << SQL.ident(name) << ' ' << sql_type(type, limit, precision, scale, array)
        io << " PRIMARY KEY" if primary_key
        io << " NOT NULL" unless null || primary_key
        io << " DEFAULT " << default_sql if default_sql
        io << " DEFAULT " << SQL.literal(default) if default_sql.nil? && !default.nil?
        io << " UNIQUE" if unique
        io << " CHECK (" << check << ')' if check
      end
    end

    def self.sql_type(type : Symbol | String, limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil, array : Bool = false) : String
      base = case type
             when Symbol
               TYPES[type]? || raise ArgumentError.new("unknown column type #{type.inspect}; known: #{TYPES.keys.join(", ")} (or pass a SQL type string)")
             else
               validate_type(type)
             end
      base = "character varying(#{limit})" if type == :string && limit
      base = "numeric(#{precision}#{scale ? ", #{scale}" : ""})" if type == :decimal && precision
      array ? "#{base}[]" : base
    end

    # Raw SQL types are allowed ("citext", "text[]", "numeric(10,2)", a custom enum) but only plain type syntax.
    private def self.validate_type(type : String) : String
      raise ArgumentError.new("invalid SQL type #{type.inspect}") unless type.matches?(/\A[A-Za-z_][A-Za-z0-9_ ]*(\([0-9, ]+\))?(\[\])?\z/)
      type
    end

    # Collects what `create_table` should emit: the CREATE TABLE, then its indexes.
    #
    # ```
    # create_table :posts do |t|
    #   t.references :user, on_delete: :cascade
    #   t.string :title, limit: 120
    #   t.text :body, null: true
    #   t.jsonb :meta, default_sql: "'{}'::jsonb"
    #   t.array :tags, :text, default_sql: "'{}'"
    #   t.timestamps
    #   t.index :title, unique: true
    #   t.index :meta, using: :gin
    # end
    # ```
    #
    # Columns are NOT NULL unless `null: true`, matching non-nilable Crystal properties.
    class TableBuilder
      getter name : String
      getter columns = [] of String
      getter constraints = [] of String
      getter indexes = [] of String

      def initialize(table : Symbol | String, id : Symbol | Bool = :bigserial)
        @name = table.to_s
        case id
        when :bigserial then @columns << %("id" BIGSERIAL PRIMARY KEY)
        when :serial    then @columns << %("id" SERIAL PRIMARY KEY)
        when :uuid      then @columns << %("id" UUID PRIMARY KEY DEFAULT gen_random_uuid())
        when :bigint    then @columns << %("id" BIGINT PRIMARY KEY)
        when false      then nil
        else
          raise ArgumentError.new("unknown id type #{id.inspect}; use :bigserial, :serial, :uuid, :bigint or false")
        end
      end

      def column(name : Symbol | String, type : Symbol | String, null : Bool = false, default : Literal = nil, default_sql : String? = nil,
                 unique : Bool = false, check : String? = nil, limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil,
                 array : Bool = false, index : Bool = false) : Nil
        @columns << Migrations.column_sql(name, type, null, default, default_sql, unique, check, limit, precision, scale, array)
        self.index(name) if index
      end

      {% for method, type in {string: :string, text: :text, integer: :integer, smallint: :smallint, bigint: :bigint, float: :float, boolean: :boolean,
                              date: :date, time: :time, datetime: :datetime, uuid: :uuid, json: :json, jsonb: :jsonb, binary: :binary,
                              inet: :inet, citext: :citext, hstore: :hstore} %}
        def {{method.id}}(name : Symbol | String, null : Bool = false, default : Literal = nil, default_sql : String? = nil, unique : Bool = false,
                          check : String? = nil, index : Bool = false{% if method == :string %}, limit : Int32? = nil{% end %}) : Nil
          column(name, {{type}}, null: null, default: default, default_sql: default_sql, unique: unique, check: check, index: index{% if method == :string %}, limit: limit{% end %})
        end
      {% end %}

      def decimal(name : Symbol | String, precision : Int32? = nil, scale : Int32? = nil, null : Bool = false, default : Literal = nil,
                  default_sql : String? = nil, index : Bool = false) : Nil
        column(name, :decimal, null: null, default: default, default_sql: default_sql, precision: precision, scale: scale, index: index)
      end

      # `t.array :tags, :text` -> `tags text[]`
      def array(name : Symbol | String, of type : Symbol | String, null : Bool = false, default_sql : String? = nil, index : Bool = false) : Nil
        column(name, type, null: null, default_sql: default_sql, array: true)
        self.index(name, using: :gin) if index
      end

      # `t.enum_column :status, :user_status` (create the type first with `create_enum`).
      def enum_column(name : Symbol | String, type_name : Symbol | String, null : Bool = false, default : String? = nil, index : Bool = false) : Nil
        @columns << Migrations.column_sql(name, SQL.ident(type_name).delete('"'), null, default)
        self.index(name) if index
      end

      # `t.references :user` adds `user_id bigint NOT NULL`, its foreign key and an index.
      def references(name : Symbol | String, to : Symbol | String | Nil = nil, type : Symbol | String = :bigint, null : Bool = false,
                     index : Bool = true, foreign_key : Bool = true, on_delete : Symbol | String | Nil = nil, on_update : Symbol | String | Nil = nil,
                     primary_key : String = "id", column : Symbol | String | Nil = nil) : Nil
        fk_column = (column || "#{name}_id").to_s
        @columns << Migrations.column_sql(fk_column, type, null)
        target = to || "#{name}s"
        self.foreign_key(fk_column, to: target, primary_key: primary_key, on_delete: on_delete, on_update: on_update) if foreign_key
        self.index(fk_column) if index
      end

      def timestamps(null : Bool = false) : Nil
        {:created_at, :updated_at}.each { |name| @columns << Migrations.column_sql(name, :datetime, null, default_sql: "now()") }
      end

      # `deleted_at timestamptz NULL` for `soft_delete` models.
      def soft_delete : Nil
        @columns << Migrations.column_sql(:deleted_at, :datetime, true)
      end

      def foreign_key(column : Symbol | String, to : Symbol | String, primary_key : String = "id", on_delete : Symbol | String | Nil = nil,
                      on_update : Symbol | String | Nil = nil, name : String? = nil) : Nil
        @constraints << foreign_key_sql(column, to, primary_key, on_delete, on_update, name)
      end

      def unique(columns : Array(Symbol | String), name : String? = nil) : Nil
        constraint = name ? "CONSTRAINT #{SQL.ident(name)} " : ""
        @constraints << "#{constraint}UNIQUE (#{columns.map { |column| SQL.ident(column) }.join(", ")})"
      end

      def check(expression : String, name : String? = nil) : Nil
        constraint = name ? "CONSTRAINT #{SQL.ident(name)} " : ""
        @constraints << "#{constraint}CHECK (#{expression})"
      end

      # `t.index :email, unique: true`, `t.index [:a, :b]`, `t.index :meta, using: :gin`,
      # `t.index :email, where: "deleted_at IS NULL"`. (`concurrent:` only makes sense with `add_index`.)
      def index(columns : Symbol | String | Array(Symbol | String), unique : Bool = false, name : String? = nil, using : Symbol | String | Nil = nil,
                where : String? = nil, covering : Array(Symbol | String)? = nil, opclass : String? = nil, expression : String? = nil) : Nil
        list = columns.is_a?(Array) ? columns : [columns.as(Symbol | String)]
        @indexes << SQL.create_index(@name, list, unique, name, using, where, covering, expression, opclass)
      end

      # CREATE TABLE followed by one CREATE INDEX per declared index.
      def statements(if_not_exists : Bool = false) : Array(String)
        definition = (@columns + @constraints).join(",\n  ")
        ["CREATE TABLE #{"IF NOT EXISTS " if if_not_exists}#{SQL.ident(@name)} (\n  #{definition}\n)"] + @indexes
      end

      private def foreign_key_sql(column, to, primary_key, on_delete, on_update, name) : String
        String.build do |io|
          io << "CONSTRAINT " << SQL.ident(name) << ' ' if name
          io << "FOREIGN KEY (" << SQL.ident(column) << ") REFERENCES " << SQL.ident(to) << " (" << SQL.ident(primary_key) << ')'
          io << " ON DELETE " << SQL.action(on_delete) if on_delete
          io << " ON UPDATE " << SQL.action(on_update) if on_update
        end
      end
    end
  end
end
