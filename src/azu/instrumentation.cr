module Azu
  # The seam between core and the optional subsystems (`require "azu/dev"`, APM integrations).
  #
  # Core code wraps what is worth measuring in `Instrumentation.cache` / `Instrumentation.component`
  # and announces the app lifecycle with `Instrumentation.prepare` / `.finalize`. With nobody
  # listening, or when every listener's `enabled` check says no, each call is a nil check and a plain
  # `yield`. Subscribers and hooks are registered at require time and only read afterwards, so they need
  # no locking. A subscriber or hook that raises is logged at debug level and never breaks the
  # operation it observes.
  module Instrumentation
    # One finished cache operation. `hit` is only set for `"get"`.
    record CacheOperation,
      key : String,
      operation : String,
      store : String,
      key_size : Int32,
      value_size : Int32?,
      ttl : Time::Span?,
      duration_ms : Float64,
      hit : Bool?,
      error : String?

    # One finished call through `Azu::Redis::Client#run`: *operation* is the caller's label, *client* the
    # `Azu::Redis::Config#name`, and *error* the message of the exception it ended with, if any.
    record RedisCommand,
      operation : String,
      client : String,
      duration_ms : Float64,
      error : String?

    # One finished component lifecycle step (`mount`, `unmount`, `refresh`, `event_handler:<name>`).
    record ComponentEvent,
      id : String,
      type : String,
      event : String,
      age : Time::Span,
      duration_ms : Float64,
      memory_before : Int64,
      memory_after : Int64

    alias Hook = Configuration ->

    private record Subscription(T), enabled : Proc(Bool), callback : Proc(T, Nil)

    @@cache_subscriptions = [] of Subscription(CacheOperation)
    @@component_subscriptions = [] of Subscription(ComponentEvent)
    @@redis_subscriptions = [] of Subscription(RedisCommand)
    @@exception_subscriptions = [] of Subscription(ExceptionPage::Report)
    @@prepare_hooks = [] of Hook
    @@finalize_hooks = [] of Hook

    # Listens to finished cache operations. `enabled` is asked before each operation; while it
    # answers false the operation is not reported to it (and not timed when no subscriber is enabled).
    def self.on_cache(enabled : Proc(Bool) = -> { true }, &block : CacheOperation ->) : Nil
      @@cache_subscriptions << Subscription(CacheOperation).new(enabled, ->(op : CacheOperation) { block.call(op); nil })
    end

    # Listens to finished component steps; see `on_cache` for `enabled`.
    def self.on_component(enabled : Proc(Bool) = -> { true }, &block : ComponentEvent ->) : Nil
      @@component_subscriptions << Subscription(ComponentEvent).new(enabled, ->(event : ComponentEvent) { block.call(event); nil })
    end

    # Listens to finished Redis calls (count them, time them, count errors); see `on_cache` for `enabled`.
    def self.on_redis(enabled : Proc(Bool) = -> { true }, &block : RedisCommand ->) : Nil
      @@redis_subscriptions << Subscription(RedisCommand).new(enabled, ->(command : RedisCommand) { block.call(command); nil })
    end

    # Listens to requests that failed with a server error (an unexpected exception or a 5xx `Response::Error`), with
    # the triage the exception page shows (`ExceptionPage::Report`). The dev dashboard keeps them; an error tracker
    # can forward them. See `on_cache` for `enabled`.
    def self.on_exception(enabled : Proc(Bool) = -> { true }, &block : ExceptionPage::Report ->) : Nil
      @@exception_subscriptions << Subscription(ExceptionPage::Report).new(enabled, ->(report : ExceptionPage::Report) { block.call(report); nil })
    end

    # Whether an enabled subscriber listens to exceptions, so the report is worth building.
    def self.exception? : Bool
      active?(@@exception_subscriptions)
    end

    # Reports a failed request to the enabled exception subscribers.
    def self.exception(report : ExceptionPage::Report) : Nil
      notify(@@exception_subscriptions, report)
    end

    # Runs when `Configuration#prepare` starts what an app needs to run.
    def self.on_prepare(&hook : Hook) : Nil
      @@prepare_hooks << hook
    end

    # Runs when a `Configuration` is garbage collected.
    def self.on_finalize(&hook : Hook) : Nil
      @@finalize_hooks << hook
    end

    def self.prepare(config : Configuration) : Nil
      run_hooks(@@prepare_hooks, config)
    end

    def self.finalize(config : Configuration) : Nil
      run_hooks(@@finalize_hooks, config)
    end

    # For specs: runs the block with no subscribers and hooks registered, then restores the previous ones.
    def self.isolate(&)
      saved = {@@cache_subscriptions, @@component_subscriptions, @@redis_subscriptions, @@exception_subscriptions, @@prepare_hooks, @@finalize_hooks}
      @@cache_subscriptions = [] of Subscription(CacheOperation)
      @@component_subscriptions = [] of Subscription(ComponentEvent)
      @@redis_subscriptions = [] of Subscription(RedisCommand)
      @@exception_subscriptions = [] of Subscription(ExceptionPage::Report)
      @@prepare_hooks = [] of Hook
      @@finalize_hooks = [] of Hook
      begin
        yield
      ensure
        @@cache_subscriptions, @@component_subscriptions, @@redis_subscriptions, @@exception_subscriptions, @@prepare_hooks, @@finalize_hooks = saved
      end
    end

    # Times the block and reports it to the enabled subscribers, also when it raises.
    def self.cache(key : String, operation : String, store : String, key_size : Int32 = 0,
                   value_size : Int32? = nil, ttl : Time::Span? = nil, &)
      subscribers = @@cache_subscriptions
      return yield unless active?(subscribers)

      started = Time.instant
      hit : Bool? = nil
      error : String? = nil
      begin
        result = yield
        hit = !result.nil? if operation == "get"
        result
      rescue ex
        error = ex.message || ex.class.name
        raise ex
      ensure
        notify(subscribers, CacheOperation.new(key, operation, store, key_size, value_size, ttl,
          (Time.instant - started).total_milliseconds, hit, error))
      end
    end

    # Times the block and reports it to the enabled subscribers, also when it raises.
    def self.redis(operation : String, client : String, &)
      subscribers = @@redis_subscriptions
      return yield unless active?(subscribers)

      started = Time.instant
      error : String? = nil
      begin
        yield
      rescue ex
        error = ex.message || ex.class.name
        raise ex
      ensure
        notify(subscribers, RedisCommand.new(operation, client, (Time.instant - started).total_milliseconds, error))
      end
    end

    # Times the block and reports it to the enabled subscribers when it completes.
    def self.component(id : String, type : String, event : String, mounted_at : Time, &)
      subscribers = @@component_subscriptions
      return yield unless active?(subscribers)

      started = Time.instant
      memory_before = GC.stats.heap_size.to_i64
      result = yield
      notify(subscribers, ComponentEvent.new(id, type, event, Time.utc - mounted_at,
        (Time.instant - started).total_milliseconds, memory_before, GC.stats.heap_size.to_i64))
      result
    end

    private def self.active?(subscriptions : Array(Subscription(T))) : Bool forall T
      subscriptions.any? { |subscription| enabled?(subscription) }
    end

    private def self.enabled?(subscription : Subscription) : Bool
      safely { subscription.enabled.call } == true
    end

    private def self.notify(subscriptions : Array(Subscription(T)), event : T) : Nil forall T
      subscriptions.each { |subscription| safely { subscription.callback.call(event) } if enabled?(subscription) }
    end

    private def self.run_hooks(hooks : Array(Hook), config : Configuration) : Nil
      hooks.each { |hook| safely { hook.call(config) } }
    end

    private def self.safely(&)
      yield
    rescue ex
      Log.for("azu.instrumentation").debug(exception: ex) { "Instrumentation callback failed" }
      nil
    end
  end
end
