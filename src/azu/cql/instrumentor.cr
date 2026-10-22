module Azu
  module CQL
    # Subscribes to CQL's event framework (`CQL::Telemetry`: one `QueryEvent` per statement,
    # a `TransactionEvent` per transaction state change) and records the events in
    # `Azu::QueryStore`, tagged with the current `Azu::RequestContext`. Subscribers run in the
    # fiber that issued the SQL, so the request is known and the call site can be captured.
    module Instrumentor
      # Subscriber name in `CQL::Telemetry` (subscribing again replaces, so installing twice is harmless).
      NAME = "azu.dashboard"

      # Frames from these paths are framework/driver internals, not the offending line. (No bare
      # `/crystal/`: an app checked out under a `crystal` directory would lose every call site.)
      INTERNAL_FRAMES = %w(src/azu/ lib/azu/ /cql/src/ lib/cql/ lib/db/ lib/sqlite3/ lib/pg/ lib/mysql/ /crystal/src/ /.cache/crystal/)

      def self.internal_frame?(location : String) : Bool
        location.starts_with?("??") || INTERNAL_FRAMES.any? { |internal| location.includes?(internal) }
      end

      @@mutex = Mutex.new
      @@transactions = {} of Fiber => Array(Int64)

      # True while our subscribers are registered (false again after `CQL::Telemetry.reset!`).
      def self.installed? : Bool
        ::CQL::Telemetry.subscribed?(NAME)
      end

      def self.install(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          return if installed?
          store.enabled = true
          ::CQL::Telemetry.subscribe(NAME) { |event| record_query(store, event) }
          ::CQL::Telemetry.subscribe_transactions(NAME) { |event| record_transaction(store, event) }
        end
      end

      def self.uninstall(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          ::CQL::Telemetry.unsubscribe(NAME)
          ::CQL::Telemetry.unsubscribe_transactions(NAME)
          @@transactions.clear
          store.enabled = false
        end
      end

      private def self.record_query(store : QueryStore, event : ::CQL::Telemetry::QueryEvent) : Nil
        return unless Azu::CONFIG.database.instrument?
        return if event.operation == :explain # plans are diagnostics, not application queries
        context = RequestContext.current?
        params = event.params.try(&.map { |param| truncate(param.inspect) }) || Array.new(event.param_count) { "?" }
        store.record_query(
          event.sql, params, event.duration.total_milliseconds, event.rows_affected,
          event.error.try { |error| error.message.presence || error.class.name }, call_site, current_transaction,
          context.try(&.request_id), context.try(&.endpoint), context.try(&.method), context.try(&.path),
          Fiber.current.object_id
        )
      end

      private def self.record_transaction(store : QueryStore, event : ::CQL::Telemetry::TransactionEvent) : Nil
        return unless Azu::CONFIG.database.instrument?
        fiber = Fiber.current
        case event.state
        when .begin?
          @@mutex.synchronize { (@@transactions[fiber] ||= [] of Int64) << event.id }
          context = RequestContext.current?
          store.record_transaction_begin(event.id, event.nested, context.try(&.request_id), context.try(&.endpoint))
        else
          @@mutex.synchronize do
            if stack = @@transactions[fiber]?
              stack.delete(event.id)
              @@transactions.delete(fiber) if stack.empty?
            end
          end
          error = event.error.try { |failure| failure.message.presence || failure.class.name }
          store.record_transaction_end(event.id, event.state.commit?, event.duration.total_milliseconds, error)
        end
      end

      private def self.current_transaction : Int64?
        @@mutex.synchronize { @@transactions[Fiber.current]?.try(&.last?) }
      end

      # First stack frame outside CQL/Azu/driver code, as "path:line".
      private def self.call_site : String?
        caller.each do |frame|
          location = frame.split(" in ", 2).first
          next if internal_frame?(location)
          return location.split(':').first(2).join(':')
        end
        nil
      end

      private def self.truncate(value : String, limit : Int32 = 200) : String
        value.size > limit ? "#{value[0, limit]}…" : value
      end
    end
  end
end
