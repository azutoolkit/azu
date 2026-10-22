module Azu
  module Migrations
    class InvalidIdentifier < ArgumentError
    end

    # Escaping for the DDL the migration DSL generates. DDL cannot use bind
    # parameters, so every name and literal goes through here.
    module SQL
      extend self

      IDENTIFIER          = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      INDEX_USING         = %w(btree hash gin gist spgist brin)
      REFERENTIAL_ACTIONS = {
        "cascade"     => "CASCADE",
        "restrict"    => "RESTRICT",
        "nullify"     => "SET NULL",
        "set_null"    => "SET NULL",
        "set_default" => "SET DEFAULT",
        "no_action"   => "NO ACTION",
      }

      # "users" or "public.users" -> "\"users\"" / "\"public\".\"users\""
      def ident(name : Symbol | String) : String
        text = name.to_s
        parts = text.split('.')
        raise InvalidIdentifier.new("invalid identifier #{text.inspect}") if parts.size > 2 || parts.any? { |part| !part.matches?(IDENTIFIER) }
        parts.map { |part| %("#{part}") }.join('.')
      end

      def literal(value : Nil) : String
        "NULL"
      end

      def literal(value : Bool) : String
        value ? "TRUE" : "FALSE"
      end

      def literal(value : Int | Float) : String
        value.to_s
      end

      def literal(value : Symbol) : String
        literal(value.to_s)
      end

      def literal(value : String) : String
        "'#{value.gsub("'", "''")}'"
      end

      def literal(value : Time) : String
        literal(value.to_utc.to_s("%Y-%m-%d %H:%M:%S.%6N+00"))
      end

      def literal(value : JSON::Any) : String
        literal(value.to_json)
      end

      def action(value : Symbol | String) : String
        REFERENTIAL_ACTIONS[value.to_s.downcase]? || raise ArgumentError.new("unknown referential action #{value.inspect}; use #{REFERENTIAL_ACTIONS.keys.join(", ")}")
      end

      # An index column: a plain name, optionally "name DESC" / "name ASC NULLS LAST".
      def index_column(column : Symbol | String) : String
        text = column.to_s.strip
        match = text.match(/\A([A-Za-z_][A-Za-z0-9_]*)(?:\s+(ASC|DESC))?(?:\s+NULLS\s+(FIRST|LAST))?\z/i)
        raise InvalidIdentifier.new("invalid index column #{text.inspect}") unless match
        String.build do |io|
          io << ident(match[1])
          io << ' ' << match[2].upcase if match[2]?
          io << " NULLS " << match[3].upcase if match[3]?
        end
      end

      def index_name(table : Symbol | String, columns : Array(String), explicit : String? = nil) : String
        name = explicit || "index_#{table.to_s.tr(".", "_")}_on_#{columns.map { |column| column.split(' ').first }.join("_and_")}"
        # PostgreSQL truncates identifiers at 63 bytes; keep names unique when that happens.
        name.bytesize > 63 ? "#{name[0, 54]}_#{name.hash.to_s(16)[0, 8]}" : name
      end

      # CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] name ON table [USING m] (cols) [INCLUDE (..)] [WHERE ..]
      def create_index(table : Symbol | String, columns : Array(Symbol | String), unique : Bool = false, name : String? = nil,
                       using : Symbol | String | Nil = nil, where : String? = nil, covering : Array(Symbol | String)? = nil,
                       expression : String? = nil, opclass : String? = nil, concurrent : Bool = false, if_not_exists : Bool = false) : String
        method = using.try(&.to_s.downcase)
        raise ArgumentError.new("unknown index method #{using.inspect}; use #{INDEX_USING.join(", ")}") if method && !INDEX_USING.includes?(method)
        raise ArgumentError.new("give columns or an expression for the index") if columns.empty? && expression.nil?

        rendered = columns.map { |column| index_column(column) }
        names = columns.map(&.to_s)
        key = expression ? [expression] : rendered.map { |column| opclass ? "#{column} #{opclass}" : column }
        String.build do |io|
          io << "CREATE "
          io << "UNIQUE " if unique
          io << "INDEX "
          io << "CONCURRENTLY " if concurrent
          io << "IF NOT EXISTS " if if_not_exists
          io << ident(index_name(table, names.empty? ? ["expr"] : names, name)) << " ON " << ident(table)
          io << " USING " << method if method
          io << " (" << key.join(", ") << ")"
          if covering && !covering.empty?
            io << " INCLUDE (" << covering.map { |column| ident(column) }.join(", ") << ")"
          end
          io << " WHERE " << where if where
        end
      end

      def drop_index(name : String, concurrent : Bool = false, if_exists : Bool = true) : String
        String.build do |io|
          io << "DROP INDEX "
          io << "CONCURRENTLY " if concurrent
          io << "IF EXISTS " if if_exists
          io << ident(name)
        end
      end
    end
  end
end
