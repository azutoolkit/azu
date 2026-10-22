module Azu
  module CQL
    # Subscribes to `cql.query`, `cql.transaction` and `cql.connect` and records
    # them into `Azu::QueryStore`, tagged with the current `Azu::RequestContext`.
    # Handlers run in the fiber that issued the SQL, so the request is known
    # and the call site can be captured.
    module Instrumentor
      # Frames from these paths are framework/driver internals, not the offending line. (No bare
      # `/crystal/`: an app checked out under a `crystal` directory would lose every call site.)
      INTERNAL_FRAMES = %w(src/azu/ lib/azu/ /cql/src/ lib/cql/ lib/db/ lib/sqlite3/ lib/pg/ lib/mysql/ /crystal/src/ /.cache/crystal/)

      def self.internal_frame?(location : String) : Bool
        location.starts_with?("??") || INTERNAL_FRAMES.any? { |internal| location.includes?(internal) }
      end

      @@mutex = Mutex.new
      @@subscriptions = [] of ::CQL::Events::Subscription
      @@transactions = {} of Fiber => Array(Int64)

      def self.installed? : Bool
        @@mutex.synchronize { !@@subscriptions.empty? }
      end

      def self.install(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          return unless @@subscriptions.empty?
          store.enabled = true
          @@subscriptions << ::CQL::Events.on_query { |event| record_query(store, event) }
          @@subscriptions << ::CQL::Events.on_transaction { |event| record_transaction(store, event) }
          @@subscriptions << ::CQL::Events.on_connect do |event|
            Azu::CONFIG.log.debug { "cql.connect schema=#{event.schema} adapter=#{event.adapter} uri=#{event.uri}" }
          end
        end
      end

      def self.uninstall(store : QueryStore = QueryStore.instance) : Nil
        @@mutex.synchronize do
          @@subscriptions.each { |subscription| ::CQL::Events.unsubscribe(subscription) }
          @@subscriptions.clear
          @@transactions.clear
          store.enabled = false
        end
      end

      private def self.record_query(store : QueryStore, event : ::CQL::Events::QueryEvent) : Nil
        return unless Azu::CONFIG.database.instrument?
        context = RequestContext.current?
        store.record_query(
          event.sql, event.params.map { |param| truncate(param.inspect) }, event.duration_ms, event.rows,
          event.error, call_site, current_transaction,
          context.try(&.request_id), context.try(&.endpoint), context.try(&.method), context.try(&.path),
          Fiber.current.object_id
        )
      end

      private def self.record_transaction(store : QueryStore, event : ::CQL::Events::TransactionEvent) : Nil
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
          store.record_transaction_end(event.id, event.state.commit?, event.duration_ms, event.error)
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
