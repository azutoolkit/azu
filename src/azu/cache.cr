require "json"
require "digest/sha256"
require "redis"

# Conditionally require performance metrics only when needed
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  require "./performance_metrics"
{% end %}

module Azu
  # Core caching module for the Azu framework
  # Provides Rails-like caching functionality with multiple store implementations
  #
  # Usage:
  # ```
  # # Basic usage
  # Azu.cache.get("key")                    # => String?
  # Azu.cache.set("key", "value", ttl: 300) # => Bool
  #
  # # Block syntax (Rails-like)
  # result = Azu.cache.fetch("expensive_key", ttl: 1.hour) do
  #   expensive_operation()
  # end
  # ```
  module Cache
    # Base cache store interface
    abstract class Store
      abstract def get(key : String) : String?
      abstract def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
      abstract def delete(key : String) : Bool
      abstract def exists?(key : String) : Bool
      abstract def clear : Bool
      abstract def size : Int32

      # Overloaded get method with block and TTL support (Rails-like)
      def get(key : String, ttl : Time::Span? = nil, & : -> String) : String
        if cached = get(key)
          cached
        else
          value = yield
          set(key, value, ttl)
          value
        end
      end

      # Rails-like fetch method with block support
      def fetch(key : String, ttl : Time::Span? = nil, & : -> String) : String
        if cached = get(key)
          cached
        else
          value = yield
          set(key, value, ttl)
          value
        end
      end

      # Multi-get support
      def get_multi(keys : Array(String)) : Hash(String, String?)
        result = Hash(String, String?).new
        keys.each do |key|
          result[key] = get(key)
        end
        result
      end

      # Multi-set support
      def set_multi(values : Hash(String, String), ttl : Time::Span? = nil) : Bool
        values.all? { |key, value| set(key, value, ttl) }
      end

      # Increment counter (for stores that support it)
      def increment(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        current = get(key)
        if current
          new_value = current.to_i + amount
          set(key, new_value.to_s, ttl)
          new_value
        else
          set(key, amount.to_s, ttl)
          amount
        end
      end

      # Decrement counter
      def decrement(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        increment(key, -amount, ttl)
      end
    end

    # Memory-based cache store with LRU eviction
    class MemoryStore < Store
      private struct CacheEntry
        getter value : String
        getter expires_at : Time?
        getter created_at : Time
        getter access_count : Int32

        def initialize(@value : String, ttl : Time::Span? = nil)
          @created_at = Time.utc
          @expires_at = ttl ? @created_at + ttl : nil
          @access_count = 1
        end

        def initialize(@value : String, @expires_at : Time?, @access_count : Int32)
          @created_at = Time.utc
        end

        def expired? : Bool
          return false unless expires_at = @expires_at
          Time.utc > expires_at
        end

        def accessed : CacheEntry
          CacheEntry.new(@value, @expires_at, @access_count + 1)
        end
      end

      DEFAULT_MAX_SIZE = 1000
      DEFAULT_TTL      = Time::Span.new(hours: 1)

      @cache : Hash(String, CacheEntry)
      @access_order : Array(String)
      @mutex : Mutex
      @max_size : Int32
      @default_ttl : Time::Span?

      def initialize(@max_size : Int32 = DEFAULT_MAX_SIZE, @default_ttl : Time::Span? = DEFAULT_TTL)
        @cache = Hash(String, CacheEntry).new
        @access_order = Array(String).new
        @mutex = Mutex.new
      end

      def get(key : String) : String?
        @mutex.synchronize do
          entry = @cache[key]?
          return nil unless entry

          if entry.expired?
            @cache.delete(key)
            @access_order.delete(key)
            return nil
          end

          # Update access order for LRU
          @access_order.delete(key)
          @access_order << key
          @cache[key] = entry.accessed

          entry.value
        end
      end

      def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
        @mutex.synchronize do
          ttl = ttl || @default_ttl

          # Remove existing entry if present
          if @cache.has_key?(key)
            @access_order.delete(key)
          elsif @cache.size >= @max_size
            # Evict least recently used entry
            evict_lru
          end

          @cache[key] = CacheEntry.new(value, ttl)
          @access_order << key
          true
        end
      end

      def delete(key : String) : Bool
        @mutex.synchronize do
          if @cache.delete(key)
            @access_order.delete(key)
            true
          else
            false
          end
        end
      end

      def exists?(key : String) : Bool
        @mutex.synchronize do
          entry = @cache[key]?
          return false unless entry
          return false if entry.expired?
          true
        end
      end

      def clear : Bool
        @mutex.synchronize do
          @cache.clear
          @access_order.clear
          true
        end
      end

      def size : Int32
        @mutex.synchronize do
          cleanup_expired
          @cache.size
        end
      end

      # Memory store specific methods
      def stats : Hash(String, Int32 | Float64)
        @mutex.synchronize do
          cleanup_expired
          {
            "size"            => @cache.size,
            "max_size"        => @max_size,
            "hit_rate"        => calculate_hit_rate,
            "memory_usage_mb" => calculate_memory_usage,
          }
        end
      end

      private def evict_lru
        return if @access_order.empty?

        lru_key = @access_order.shift
        @cache.delete(lru_key)
      end

      private def cleanup_expired
        expired_keys = [] of String
        @cache.each do |key, entry|
          expired_keys << key if entry.expired?
        end

        expired_keys.each do |key|
          @cache.delete(key)
          @access_order.delete(key)
        end
      end

      private def calculate_hit_rate : Float64
        # Simplified hit rate calculation
        # In a real implementation, you'd track hits/misses
        @cache.size.to_f / @max_size.to_f * 100.0
      end

      private def calculate_memory_usage : Float64
        # Rough estimate of memory usage in MB
        total_size = @cache.sum { |key, entry| key.bytesize + entry.value.bytesize }
        total_size.to_f / (1024 * 1024)
      end
    end

    # Redis-based cache store with Redis::PooledClient
    class RedisStore < Store
      @client : Redis::PooledClient
      @default_ttl : Time::Span?

      def initialize(redis_url : String, pool_size : Int32 = 5, timeout : Time::Span = 5.seconds, @default_ttl : Time::Span? = nil)
        @client = Redis::PooledClient.new(
          url: redis_url,
          pool_size: pool_size,
          pool_timeout: timeout.total_seconds
        )
      end

      def get(key : String) : String?
        @client.get(key)
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to get key: #{key}" }
        nil
      end

      def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
        ttl = ttl || @default_ttl
        if ttl
          @client.setex(key, ttl.total_seconds.to_i, value)
        else
          @client.set(key, value)
        end
        true
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to set key: #{key}" }
        false
      end

      def delete(key : String) : Bool
        result = @client.del(key)
        result > 0
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to delete key: #{key}" }
        false
      end

      def exists?(key : String) : Bool
        @client.exists(key) > 0
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to check existence of key: #{key}" }
        false
      end

      def clear : Bool
        @client.flushdb
        true
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to clear cache" }
        false
      end

      def size : Int32
        # Get database info as hash
        info_hash = @client.info
        # Look for db0 or current database keys count
        if keyspace = info_hash["db0"]?
          # Parse db0 value like "keys=123,expires=45"
          if keyspace =~ /keys=(\d+)/
            $1.to_i
          else
            0
          end
        else
          0
        end
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to get cache size" }
        0
      end

      # Override increment for Redis native support
      def increment(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        result = if amount == 1
                   @client.incr(key)
                 else
                   @client.incrby(key, amount)
                 end

        # Set TTL if provided and key was just created
        if ttl && result == amount
          @client.expire(key, ttl.total_seconds.to_i)
        end

        result.to_i
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to increment key: #{key}" }
        nil
      end

      # Override decrement for Redis native support
      def decrement(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        result = if amount == 1
                   @client.decr(key)
                 else
                   @client.decrby(key, amount)
                 end

        # Set TTL if provided
        if ttl
          @client.expire(key, ttl.total_seconds.to_i)
        end

        result.to_i
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to decrement key: #{key}" }
        nil
      end

      # Override multi-get for Redis native support
      def get_multi(keys : Array(String)) : Hash(String, String?)
        return Hash(String, String?).new if keys.empty?

        values = @client.mget(keys)
        result = Hash(String, String?).new
        keys.each_with_index do |key, index|
          result[key] = values[index]?.as(String | Nil)
        end
        result
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to get multiple keys" }
        # Fallback to individual gets
        super(keys)
      end

      # Override multi-set for Redis native support
      def set_multi(values : Hash(String, String), ttl : Time::Span? = nil) : Bool
        return true if values.empty?

        # Use Redis pipeline for better performance
        @client.pipelined do |pipeline|
          values.each do |key, value|
            if ttl
              pipeline.setex(key, ttl.total_seconds.to_i, value)
            else
              pipeline.set(key, value)
            end
          end
        end
        true
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Failed to set multiple keys" }
        # Fallback to individual sets
        super(values, ttl)
      end

      # Redis-specific methods
      def ping : String?
        @client.ping
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Redis ping failed" }
        nil
      end

      def info : Hash(String, String)?
        @client.info
      rescue ex
        Log.for("Azu::Cache::RedisStore").error(exception: ex) { "Redis info failed" }
        nil
      end

      def close
        # Redis::PooledClient handles connection cleanup automatically
      end
    end

    # Null store for disabled caching
    class NullStore < Store
      def get(key : String) : String?
        nil
      end

      def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
        false
      end

      def delete(key : String) : Bool
        false
      end

      def exists?(key : String) : Bool
        false
      end

      def clear : Bool
        true
      end

      def size : Int32
        0
      end
    end

    # Cache configuration
    class Configuration
      property? enabled : Bool = true
      property store : String = "memory"
      property max_size : Int32 = 1000
      property default_ttl : Int32 = 3600 # 1 hour in seconds
      property key_prefix : String = "azu"
      property? compress : Bool = false
      property? serialize : Bool = true

      # Redis-specific configuration
      property redis_url : String = "redis://localhost:6379/0"
      property redis_pool_size : Int32 = 5
      property redis_timeout : Int32 = 5

      # File cache configuration
      property file_cache_path : String = "./tmp/cache"
      property file_cache_permissions : Int32 = 0o755

      def initialize
        load_from_env
      end

      private def load_from_env
        @enabled = ENV.fetch("CACHE_ENABLED", "true").downcase == "true"
        @store = ENV.fetch("CACHE_STORE", "memory").downcase
        @max_size = ENV.fetch("CACHE_MAX_SIZE", "1000").to_i
        @default_ttl = ENV.fetch("CACHE_DEFAULT_TTL", "3600").to_i
        @key_prefix = ENV.fetch("CACHE_KEY_PREFIX", "azu")
        @compress = ENV.fetch("CACHE_COMPRESS", "false").downcase == "true"
        @serialize = ENV.fetch("CACHE_SERIALIZE", "true").downcase == "true"
        @redis_url = ENV.fetch("CACHE_REDIS_URL", "redis://localhost:6379/0")
        @redis_pool_size = ENV.fetch("CACHE_REDIS_POOL_SIZE", "5").to_i
        @redis_timeout = ENV.fetch("CACHE_REDIS_TIMEOUT", "5").to_i
        @file_cache_path = ENV.fetch("CACHE_FILE_PATH", "./tmp/cache")
        @file_cache_permissions = ENV.fetch("CACHE_FILE_PERMISSIONS", "755").to_i(8)
      end

      def ttl_span : Time::Span
        Time::Span.new(seconds: @default_ttl)
      end

      def redis_timeout_span : Time::Span
        Time::Span.new(seconds: @redis_timeout)
      end
    end

    # Main cache interface
    class Manager
      getter store : Store
      getter config : Configuration

      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        property metrics : Azu::PerformanceMetrics?

        def initialize(@config : Configuration = Configuration.new, @metrics : Azu::PerformanceMetrics? = nil)
          @store = create_store
        end
      {% else %}
        def initialize(@config : Configuration = Configuration.new)
          @store = create_store
        end
      {% end %}

      # Rails-like API methods with optional performance metrics
      def get(key : String) : String?
        return nil unless @config.enabled?

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "get", @config.store, key.bytesize
            ) do
              @store.get(prefixed_key(key))
            end
            result.as(String?)
          else
            @store.get(prefixed_key(key))
          end
        {% else %}
          @store.get(prefixed_key(key))
        {% end %}
      end

      # Overloaded get method with block and TTL support (Rails-like)
      def get(key : String, ttl : Time::Span? = nil, & : -> String) : String
        return yield unless @config.enabled?

        prefixed = prefixed_key(key)

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            cached_result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "get", @config.store, key.bytesize
            ) do
              @store.get(prefixed)
            end

            cached = cached_result.as(String?)

            if cached
              deserialize_value(cached)
            else
              value = yield
              ttl = ttl || @config.ttl_span
              serialized_value = serialize_value(value)
              set_result = Azu::PerformanceMetrics.time_cache_operation(
                metrics, key, "set", @config.store, key.bytesize, serialized_value.bytesize, ttl
              ) do
                @store.set(prefixed, serialized_value, ttl)
              end
              set_result.as(Bool)
              value
            end
          else
            if cached = @store.get(prefixed)
              deserialize_value(cached)
            else
              value = yield
              ttl = ttl || @config.ttl_span
              @store.set(prefixed, serialize_value(value), ttl)
              value
            end
          end
        {% else %}
          if cached = @store.get(prefixed)
            deserialize_value(cached)
          else
            value = yield
            ttl = ttl || @config.ttl_span
            @store.set(prefixed, serialize_value(value), ttl)
            value
          end
        {% end %}
      end

      def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
        return false unless @config.enabled?

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            ttl = ttl || @config.ttl_span
            serialized_value = serialize_value(value)
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "set", @config.store, key.bytesize, serialized_value.bytesize, ttl
            ) do
              @store.set(prefixed_key(key), serialized_value, ttl)
            end
            result.as(Bool)
          else
            ttl = ttl || @config.ttl_span
            @store.set(prefixed_key(key), serialize_value(value), ttl)
          end
        {% else %}
          ttl = ttl || @config.ttl_span
          @store.set(prefixed_key(key), serialize_value(value), ttl)
        {% end %}
      end

      def fetch(key : String, ttl : Time::Span? = nil, & : -> String) : String
        return yield unless @config.enabled?

        prefixed = prefixed_key(key)

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            cached_result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "get", @config.store, key.bytesize
            ) do
              @store.get(prefixed)
            end

            cached = cached_result.as(String?)

            if cached
              deserialize_value(cached)
            else
              value = yield
              ttl = ttl || @config.ttl_span
              serialized_value = serialize_value(value)
              set_result = Azu::PerformanceMetrics.time_cache_operation(
                metrics, key, "set", @config.store, key.bytesize, serialized_value.bytesize, ttl
              ) do
                @store.set(prefixed, serialized_value, ttl)
              end
              set_result.as(Bool)
              value
            end
          else
            if cached = @store.get(prefixed)
              deserialize_value(cached)
            else
              value = yield
              ttl = ttl || @config.ttl_span
              @store.set(prefixed, serialize_value(value), ttl)
              value
            end
          end
        {% else %}
          if cached = @store.get(prefixed)
            deserialize_value(cached)
          else
            value = yield
            ttl = ttl || @config.ttl_span
            @store.set(prefixed, serialize_value(value), ttl)
            value
          end
        {% end %}
      end

      def delete(key : String) : Bool
        return false unless @config.enabled?

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "delete", @config.store, key.bytesize
            ) do
              @store.delete(prefixed_key(key))
            end
            result.as(Bool)
          else
            @store.delete(prefixed_key(key))
          end
        {% else %}
          @store.delete(prefixed_key(key))
        {% end %}
      end

      def exists?(key : String) : Bool
        return false unless @config.enabled?

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "exists", @config.store, key.bytesize
            ) do
              @store.exists?(prefixed_key(key))
            end
            result.as(Bool)
          else
            @store.exists?(prefixed_key(key))
          end
        {% else %}
          @store.exists?(prefixed_key(key))
        {% end %}
      end

      def clear : Bool
        return false unless @config.enabled?

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, "all", "clear", @config.store, 0
            ) do
              @store.clear
            end
            result.as(Bool)
          else
            @store.clear
          end
        {% else %}
          @store.clear
        {% end %}
      end

      def size : Int32
        return 0 unless @config.enabled?
        @store.size
      end

      # Multi-key operations
      def get_multi(keys : Array(String)) : Hash(String, String?)
        return Hash(String, String?).new unless @config.enabled?

        prefixed_keys = keys.map { |key| prefixed_key(key) }
        result = @store.get_multi(prefixed_keys)

        # Convert back to original keys
        original_result = Hash(String, String?).new
        keys.each_with_index do |key, index|
          original_result[key] = result[prefixed_keys[index]]?
        end
        original_result
      end

      def set_multi(values : Hash(String, String), ttl : Time::Span? = nil) : Bool
        return false unless @config.enabled?

        prefixed_values = Hash(String, String).new
        values.each do |key, value|
          prefixed_values[prefixed_key(key)] = serialize_value(value)
        end

        ttl = ttl || @config.ttl_span
        @store.set_multi(prefixed_values, ttl)
      end

      # Counter operations
      def increment(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        return nil unless @config.enabled?
        ttl = ttl || @config.ttl_span

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "increment", @config.store, key.bytesize, nil, ttl
            ) do
              @store.increment(prefixed_key(key), amount, ttl)
            end
            result.as(Int32?)
          else
            @store.increment(prefixed_key(key), amount, ttl)
          end
        {% else %}
          @store.increment(prefixed_key(key), amount, ttl)
        {% end %}
      end

      def decrement(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
        return nil unless @config.enabled?
        ttl = ttl || @config.ttl_span

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          if metrics = @metrics
            result = Azu::PerformanceMetrics.time_cache_operation(
              metrics, key, "decrement", @config.store, key.bytesize, nil, ttl
            ) do
              @store.decrement(prefixed_key(key), amount, ttl)
            end
            result.as(Int32?)
          else
            @store.decrement(prefixed_key(key), amount, ttl)
          end
        {% else %}
          @store.decrement(prefixed_key(key), amount, ttl)
        {% end %}
      end

      # Utility methods
      def stats : Hash(String, Int32 | Float64 | String)
        base_stats = Hash(String, Int32 | Float64 | String).new
        base_stats["enabled"] = @config.enabled? ? 1 : 0
        base_stats["store_type"] = @config.store
        base_stats["size"] = size

        if @store.is_a?(MemoryStore)
          memory_stats = @store.as(MemoryStore).stats
          memory_stats.each do |key, value|
            base_stats[key] = value
          end
        end

        base_stats
      end

      # Redis-specific methods (only available when using Redis store)
      def ping : String?
        return nil unless @config.enabled? && @store.is_a?(RedisStore)
        @store.as(RedisStore).ping
      end

      def redis_info : Hash(String, String)?
        return nil unless @config.enabled? && @store.is_a?(RedisStore)
        @store.as(RedisStore).info
      end

      private def create_store : Store
        # If caching is disabled, always return a NullStore
        return NullStore.new unless @config.enabled?

        case @config.store
        when "memory"
          MemoryStore.new(@config.max_size, @config.ttl_span)
        when "redis"
          RedisStore.new(@config.redis_url, @config.redis_pool_size, @config.redis_timeout_span, @config.ttl_span)
        when "null"
          NullStore.new
        else
          raise ArgumentError.new("Unsupported cache store: #{@config.store}")
        end
      end

      private def prefixed_key(key : String) : String
        "#{@config.key_prefix}:#{key}"
      end

      private def serialize_value(value : String) : String
        # For now, just return the value as-is
        # Future: implement compression, JSON serialization, etc.
        value
      end

      private def deserialize_value(value : String) : String
        # For now, just return the value as-is
        # Future: implement decompression, JSON deserialization, etc.
        value
      end
    end
  end
end
