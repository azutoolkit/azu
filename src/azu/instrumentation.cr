module Azu
  # The seam between core and the optional subsystems (`require "azu/dev"`).
  #
  # Core code wraps what is worth measuring in `Instrumentation.cache` / `Instrumentation.component`
  # and announces the app lifecycle with `Instrumentation.prepare` / `.finalize`. With nobody listening
  # each call is a nil check and a plain `yield`. Subscribers are installed once at require time (the
  # last one set wins), so they need no locking.
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

    class_property cache_subscriber : Proc(CacheOperation, Nil)?
    class_property component_subscriber : Proc(ComponentEvent, Nil)?

    @@prepare_hooks = [] of Hook
    @@finalize_hooks = [] of Hook

    # Runs when `Configuration#prepare` starts what an app needs to run.
    def self.on_prepare(&hook : Hook) : Nil
      @@prepare_hooks << hook
    end

    # Runs when a `Configuration` is garbage collected.
    def self.on_finalize(&hook : Hook) : Nil
      @@finalize_hooks << hook
    end

    def self.prepare(config : Configuration) : Nil
      @@prepare_hooks.each(&.call(config))
    end

    def self.finalize(config : Configuration) : Nil
      @@finalize_hooks.each(&.call(config))
    end

    # Times the block and reports it, also when it raises.
    def self.cache(key : String, operation : String, store : String, key_size : Int32 = 0,
                   value_size : Int32? = nil, ttl : Time::Span? = nil, &)
      return yield unless subscriber = @@cache_subscriber

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
        subscriber.call(CacheOperation.new(key, operation, store, key_size, value_size, ttl,
          (Time.instant - started).total_milliseconds, hit, error))
      end
    end

    # Times the block and reports it when it completes.
    def self.component(id : String, type : String, event : String, mounted_at : Time, &)
      return yield unless subscriber = @@component_subscriber

      started = Time.instant
      memory_before = GC.stats.heap_size.to_i64
      result = yield
      subscriber.call(ComponentEvent.new(id, type, event, Time.utc - mounted_at,
        (Time.instant - started).total_milliseconds, memory_before, GC.stats.heap_size.to_i64))
      result
    end
  end
end
