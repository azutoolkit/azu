module Azu
  module CQL
    # Subscribes to CQL's event framework (`CQL::Telemetry`: one `QueryEvent` per statement,
    # a `TransactionEvent` per transaction state change) and records the events in
    # `Azu::QueryStore`, tagged with the current `Azu::RequestContext`. Subscribers run in the
    # fiber that issued the SQL, so the request is known and the call site can be captured.
    #
    # The subscribers are deliberately synchronous: an `async: true` subscriber runs on another fiber,
    # where neither the request, nor the call site, nor the open transaction can be seen.
    #
    # Bound values are never recorded unless `database.show_params` is on in development (see
    # `params_visible?`): the dashboard keeps `?` placeholders, and shows an error as its class and the first
    # line of its message with quoted values blanked (`QueryAnalysis.redact_error`).
    module Instrumentor
      # Marks an exception raised only to roll a transaction back on purpose (like `DB::Rollback`):
      # the dashboard shows such a rollback as rolled back, not as an error.
      module IntentionalRollback
      end

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
      @@capturing = false
      @@capture_before = false

      # True while our subscribers are registered (false again after `CQL::Telemetry.reset!`).
      def self.installed? : Bool
        ::CQL::Telemetry.subscribed?(NAME)
      end

      # Whether bound values are shown: opted in with `database.show_params` and in development.
      def self.params_visible? : Bool
        Azu.current_config.show_database_params?
      end

      # Registers both subscribers. It always subscribes again (subscribing under the same name replaces), so
      # a subscriber someone removed with `Telemetry.unsubscribe_transactions(NAME)` comes back.
      def self.install(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          store.enabled = true
          capture_params if params_visible?
          ::CQL::Telemetry.subscribe(NAME) { |event| record_query(store, event) }
          ::CQL::Telemetry.subscribe_transactions(NAME) { |event| record_transaction(store, event) }
        end
      end

      def self.uninstall(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          ::CQL::Telemetry.unsubscribe(NAME)
          ::CQL::Telemetry.unsubscribe_transactions(NAME)
          ::CQL::Telemetry.capture_params = @@capture_before if @@capturing && ::CQL::Telemetry.capture_params # still what we set
          @@capturing = false
          @@transactions.clear
          store.enabled = false
        end
      end

      # CQL leaves bound values out of its events unless asked; asked only by `database.show_params`.
      private def self.capture_params : Nil
        unless @@capturing
          @@capture_before = ::CQL::Telemetry.capture_params
          @@capturing = true
        end
        ::CQL::Telemetry.capture_params = true
      end

      private def self.record_query(store : QueryStore, event : ::CQL::Telemetry::QueryEvent) : Nil
        return unless Azu::CONFIG.database.instrument?
        return if event.operation == :explain # plans are diagnostics, not application queries
        context = RequestContext.current?
        store.record_query(
          event.sql, params(event), event.duration.total_milliseconds, event.rows_affected,
          event.error.try { |error| error_text(error) }, call_site, current_transaction,
          context.try(&.request_id), context.try(&.endpoint), context.try(&.method), context.try(&.path),
          Fiber.current.object_id, operation(event), pool_wait_ms(event), event.context, event.adapter.to_s, shown?(event)
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
          error = event.error.try { |failure| error_text(failure) unless intentional?(failure) }
          store.record_transaction_end(event.id, event.state.commit?, event.duration.total_milliseconds, error)
        end
      end

      # `?` placeholders, or the bound values when they may be shown (and CQL captured them).
      private def self.params(event : ::CQL::Telemetry::QueryEvent) : Array(String)
        values = event.params if params_visible?
        values.try(&.map { |value| describe(value) }) || Array.new(event.param_count) { "?" }
      end

      private def self.shown?(event : ::CQL::Telemetry::QueryEvent) : Bool
        params_visible? && !event.params.nil?
      end

      private def self.describe(value : DB::Any) : String
        value.is_a?(Bytes) ? "<#{value.size} bytes>" : truncate(value.inspect)
      end

      # CQL labels statements it builds itself (`:select`, `:insert`, ...); everything it cannot classify, such
      # as raw `schema.exec`, is `:ddl`, so the first keyword of the SQL decides there.
      private def self.operation(event : ::CQL::Telemetry::QueryEvent) : String
        event.operation == :ddl ? QueryAnalysis.operation(event.sql) : event.operation.to_s.upcase
      end

      # Time spent waiting for a pooled connection, reported by CQL releases that measure it.
      private def self.pool_wait_ms(event : ::CQL::Telemetry::QueryEvent) : Float64
        {% if ::CQL::Telemetry::QueryEvent.has_method?("pool_wait") %}
          event.pool_wait.total_milliseconds
        {% else %}
          0.0
        {% end %}
      end

      private def self.error_text(error : Exception) : String
        message = error.message.presence
        return error.class.name unless message
        params_visible? ? message : "#{error.class.name}: #{QueryAnalysis.redact_error(message)}"
      end

      private def self.intentional?(error : Exception) : Bool
        error.is_a?(DB::Rollback) || error.is_a?(IntentionalRollback)
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
