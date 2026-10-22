require "cql"

module Azu
  module Database
    # Table definitions contributed by `Azu::Model` classes (via `column`).
    #
    # CQL reads `schema.tables[table].columns` at runtime (inserts, updates,
    # timestamps), so the connection's schema is populated from these builders
    # instead of a hand-written `Schema.define` block. Physical tables are
    # created by migrations, never by this registry.
    module Registry
      alias Builder = Proc(::CQL::Table, Nil)

      @@mutex = Mutex.new
      @@builders = {} of Symbol => Array(Builder)
      @@listener : Proc(Symbol, Nil)? = nil

      def self.add(table : Symbol, builder : Builder) : Nil
        @@mutex.synchronize { (@@builders[table] ||= [] of Builder) << builder }
        @@listener.try(&.call(table))
      end

      def self.tables : Array(Symbol)
        @@mutex.synchronize { @@builders.keys }
      end

      def self.any? : Bool
        @@mutex.synchronize { !@@builders.empty? }
      end

      def self.builders(table : Symbol) : Array(Builder)
        @@mutex.synchronize { (@@builders[table]? || [] of Builder).dup }
      end

      # Called whenever a table gains a column after the schema was built.
      def self.listener=(listener : Proc(Symbol, Nil)?)
        @@listener = listener
      end

      # Rebuilds `table` inside `schema` from the registered builders.
      def self.apply(schema : ::CQL::Schema, table : Symbol) : Nil
        definition = ::CQL::Table.new(table, schema)
        builders(table).each { |builder| builder.call(definition) }
        schema.tables[table] = definition
        nil
      end

      def self.apply_all(schema : ::CQL::Schema) : Nil
        tables.each { |table| apply(schema, table) }
      end

      def self.clear : Nil
        @@mutex.synchronize { @@builders.clear }
      end
    end
  end
end
