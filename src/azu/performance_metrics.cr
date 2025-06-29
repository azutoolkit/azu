require "time"
require "json"

module Azu
  # Performance metrics collection and analysis system
  # Tracks request processing times, memory usage, component lifecycle, and error rates
  class PerformanceMetrics
    # JSON converter for Time::Span fields
    module TimeSpanConverter
      def self.from_json(value : JSON::PullParser) : Time::Span?
        case value.kind
        when .null?
          value.read_null
          nil
        when .float?, .int?
          Time::Span.new(seconds: value.read_float)
        else
          raise JSON::ParseException.new("Expected Number or Null for Time::Span", value.location)
        end
      end

      def self.to_json(value : Time::Span?, json : JSON::Builder) : Nil
        if value
          json.number(value.total_seconds)
        else
          json.null
        end
      end
    end

    # Individual metric data point
    struct MetricPoint
      include JSON::Serializable

      getter timestamp : Time
      getter value : Float64
      getter metadata : Hash(String, String)

      def initialize(@timestamp : Time, @value : Float64, @metadata = {} of String => String)
      end
    end

    # Cache operation metrics
    struct CacheMetric
      include JSON::Serializable

      getter key : String
      getter operation : String  # get, set, delete, exists, clear, increment, decrement
      getter store_type : String # memory, redis, null
      getter hit : Bool?         # true for hit, false for miss, nil for non-get operations
      getter processing_time : Float64
      getter key_size : Int32
      getter value_size : Int32?
      @[JSON::Field(converter: Azu::PerformanceMetrics::TimeSpanConverter)]
      getter ttl : Time::Span?
      getter timestamp : Time
      getter error : String? # Error message if operation failed

      def initialize(@key : String, @operation : String, @store_type : String,
                     @processing_time : Float64, @timestamp : Time,
                     @hit : Bool? = nil, @key_size : Int32 = 0,
                     @value_size : Int32? = nil, @ttl : Time::Span? = nil,
                     @error : String? = nil)
      end

      def successful?
        @error.nil?
      end

      def hit?
        @hit == true
      end

      def miss?
        @hit == false
      end

      def ttl_seconds
        @ttl.try(&.total_seconds.to_i)
      end
    end

    # Request-specific metrics
    struct RequestMetric
      include JSON::Serializable

      getter endpoint : String
      getter method : String
      getter path : String
      getter processing_time : Float64
      getter memory_before : Int64
      getter memory_after : Int64
      getter memory_delta : Int64
      getter status_code : Int32
      getter timestamp : Time
      getter request_id : String?

      def initialize(@endpoint : String, @method : String, @path : String,
                     @processing_time : Float64, @memory_before : Int64,
                     @memory_after : Int64, @status_code : Int32,
                     @timestamp : Time, @request_id : String? = nil)
        @memory_delta = @memory_after - @memory_before
      end

      def error?
        @status_code >= 400
      end

      def memory_usage_mb
        (@memory_delta / 1024.0 / 1024.0).round(2)
      end
    end

    # Component lifecycle metrics
    struct ComponentMetric
      include JSON::Serializable

      getter component_id : String
      getter component_type : String
      getter event : String # mount, unmount, refresh, event_handler
      getter processing_time : Float64?
      getter memory_before : Int64?
      getter memory_after : Int64?
      getter timestamp : Time
      @[JSON::Field(converter: Azu::PerformanceMetrics::TimeSpanConverter)]
      getter age_at_event : Time::Span?

      def initialize(@component_id : String, @component_type : String,
                     @event : String, @timestamp : Time,
                     @processing_time : Float64? = nil,
                     @memory_before : Int64? = nil,
                     @memory_after : Int64? = nil,
                     @age_at_event : Time::Span? = nil)
      end

      def memory_delta
        return nil unless mb = @memory_before
        return nil unless ma = @memory_after
        ma - mb
      end
    end

    # Aggregated statistics for analysis
    struct AggregatedStats
      include JSON::Serializable

      getter total_requests : Int32
      getter error_requests : Int32
      getter avg_response_time : Float64
      getter min_response_time : Float64
      getter max_response_time : Float64
      getter p95_response_time : Float64
      getter p99_response_time : Float64
      getter error_rate : Float64
      getter avg_memory_usage : Float64
      getter peak_memory_usage : Float64
      getter total_memory_allocated : Int64
      getter start_time : Time
      getter end_time : Time

      def initialize(@total_requests, @error_requests, @avg_response_time,
                     @min_response_time, @max_response_time, @p95_response_time,
                     @p99_response_time, @error_rate, @avg_memory_usage,
                     @peak_memory_usage, @total_memory_allocated, @start_time, @end_time)
      end
    end

    private MUTEX       = Mutex.new
    private MAX_METRICS = 10000 # Prevent memory bloat

    @request_metrics = [] of RequestMetric
    @component_metrics = [] of ComponentMetric
    @cache_metrics = [] of CacheMetric
    @error_counts = Hash(String, Int32).new(0)
    @cache_error_counts = Hash(String, Int32).new(0)
    @cache_operation_counts = Hash(String, Int32).new(0)
    @cache_hit_counts = Hash(String, Int32).new(0)
    @cache_miss_counts = Hash(String, Int32).new(0)
    @endpoint_stats = Hash(String, Array(Float64)).new { |h, k| h[k] = [] of Float64 }
    @start_time = Time.utc
    @enabled = true

    getter :start_time, :enabled

    def initialize(@enabled = true)
    end

    # Enable/disable metrics collection
    def enabled=(@enabled : Bool)
    end

    # Record a request metric
    def record_request(endpoint : String, method : String, path : String,
                       processing_time : Float64, memory_before : Int64,
                       memory_after : Int64, status_code : Int32,
                       request_id : String? = nil)
      return unless @enabled

      metric = RequestMetric.new(
        endpoint: endpoint,
        method: method,
        path: path,
        processing_time: processing_time,
        memory_before: memory_before,
        memory_after: memory_after,
        status_code: status_code,
        timestamp: Time.utc,
        request_id: request_id
      )

      MUTEX.synchronize do
        @request_metrics << metric
        @error_counts[endpoint] += 1 if metric.error?
        @endpoint_stats[endpoint] << processing_time

        # Prevent memory bloat by keeping only recent metrics
        if @request_metrics.size > MAX_METRICS
          @request_metrics.shift
        end

        if @endpoint_stats[endpoint].size > 1000
          @endpoint_stats[endpoint].shift
        end
      end
    end

    # Record a component lifecycle metric
    def record_component(component_id : String, component_type : String,
                         event : String, processing_time : Float64? = nil,
                         memory_before : Int64? = nil, memory_after : Int64? = nil,
                         age_at_event : Time::Span? = nil)
      return unless @enabled

      metric = ComponentMetric.new(
        component_id: component_id,
        component_type: component_type,
        event: event,
        timestamp: Time.utc,
        processing_time: processing_time,
        memory_before: memory_before,
        memory_after: memory_after,
        age_at_event: age_at_event
      )

      MUTEX.synchronize do
        @component_metrics << metric

        # Prevent memory bloat
        if @component_metrics.size > MAX_METRICS
          @component_metrics.shift
        end
      end
    end

    # Record a cache operation metric
    def record_cache(key : String, operation : String, store_type : String,
                     processing_time : Float64, hit : Bool? = nil,
                     key_size : Int32 = 0, value_size : Int32? = nil,
                     ttl : Time::Span? = nil, error : String? = nil)
      return unless @enabled

      metric = CacheMetric.new(
        key: key,
        operation: operation,
        store_type: store_type,
        processing_time: processing_time,
        timestamp: Time.utc,
        hit: hit,
        key_size: key_size,
        value_size: value_size,
        ttl: ttl,
        error: error
      )

      MUTEX.synchronize do
        @cache_metrics << metric

        # Track operation counts
        @cache_operation_counts[operation] += 1

        # Track errors
        if error
          @cache_error_counts[operation] += 1
        end

        # Track hits/misses for get operations
        if operation == "get" && hit != nil
          if hit
            @cache_hit_counts[store_type] += 1
          else
            @cache_miss_counts[store_type] += 1
          end
        end

        # Prevent memory bloat
        if @cache_metrics.size > MAX_METRICS
          @cache_metrics.shift
        end
      end
    end

    # Get aggregated statistics
    def aggregate_stats(since : Time? = nil) : AggregatedStats
      since ||= @start_time

      MUTEX.synchronize do
        relevant_metrics = @request_metrics.select { |m| m.timestamp >= since }

        return AggregatedStats.new(
          total_requests: 0,
          error_requests: 0,
          avg_response_time: 0.0,
          min_response_time: 0.0,
          max_response_time: 0.0,
          p95_response_time: 0.0,
          p99_response_time: 0.0,
          error_rate: 0.0,
          avg_memory_usage: 0.0,
          peak_memory_usage: 0.0,
          total_memory_allocated: 0_i64,
          start_time: since,
          end_time: Time.utc
        ) if relevant_metrics.empty?

        response_times = relevant_metrics.map(&.processing_time).sort!
        error_count = relevant_metrics.count(&.error?)
        memory_deltas = relevant_metrics.map(&.memory_delta)

        AggregatedStats.new(
          total_requests: relevant_metrics.size,
          error_requests: error_count,
          avg_response_time: response_times.sum / response_times.size,
          min_response_time: response_times.first,
          max_response_time: response_times.last,
          p95_response_time: percentile(response_times, 0.95),
          p99_response_time: percentile(response_times, 0.99),
          error_rate: (error_count.to_f / relevant_metrics.size * 100).round(2),
          avg_memory_usage: memory_deltas.sum.to_f / memory_deltas.size / 1024.0 / 1024.0,
          peak_memory_usage: memory_deltas.max.to_f / 1024.0 / 1024.0,
          total_memory_allocated: memory_deltas.select(&.> 0).sum,
          start_time: since,
          end_time: Time.utc
        )
      end
    end

    # Get endpoint-specific statistics
    def endpoint_stats(endpoint : String, since : Time? = nil) : Hash(String, Float64)
      since ||= @start_time

      MUTEX.synchronize do
        metrics = @request_metrics.select { |m| m.endpoint == endpoint && m.timestamp >= since }
        return {} of String => Float64 if metrics.empty?

        response_times = metrics.map(&.processing_time).sort!
        error_count = metrics.count(&.error?)

        {
          "total_requests"      => metrics.size.to_f,
          "error_requests"      => error_count.to_f,
          "error_rate"          => (error_count.to_f / metrics.size * 100).round(2),
          "avg_response_time"   => response_times.sum / response_times.size,
          "min_response_time"   => response_times.first,
          "max_response_time"   => response_times.last,
          "p95_response_time"   => percentile(response_times, 0.95),
          "p99_response_time"   => percentile(response_times, 0.99),
          "avg_memory_usage_mb" => metrics.map(&.memory_usage_mb).sum / metrics.size,
        }
      end
    end

    # Get component statistics
    def component_stats(component_type : String? = nil, since : Time? = nil) : Hash(String, Float64)
      since ||= @start_time

      MUTEX.synchronize do
        metrics = @component_metrics.select do |m|
          m.timestamp >= since && (component_type.nil? || m.component_type == component_type)
        end

        return {} of String => Float64 if metrics.empty?

        mount_events = metrics.select { |m| m.event == "mount" }
        unmount_events = metrics.select { |m| m.event == "unmount" }
        refresh_events = metrics.select { |m| m.event == "refresh" }

        {
          "total_components"  => metrics.map(&.component_id).uniq!.size.to_f,
          "mount_events"      => mount_events.size.to_f,
          "unmount_events"    => unmount_events.size.to_f,
          "refresh_events"    => refresh_events.size.to_f,
          "avg_component_age" => mount_events.compact_map(&.age_at_event).map(&.total_seconds).sum / mount_events.size,
        }
      end
    end

    # Get cache statistics
    def cache_stats(store_type : String? = nil, since : Time? = nil) : Hash(String, Float64)
      since ||= @start_time

      MUTEX.synchronize do
        metrics = @cache_metrics.select do |m|
          m.timestamp >= since && (store_type.nil? || m.store_type == store_type)
        end

        return {} of String => Float64 if metrics.empty?

        get_operations = metrics.select { |m| m.operation == "get" }
        set_operations = metrics.select { |m| m.operation == "set" }
        delete_operations = metrics.select { |m| m.operation == "delete" }
        error_operations = metrics.select { |m| !m.successful? }
        hit_operations = get_operations.select(&.hit?)
        miss_operations = get_operations.select(&.miss?)

        # Calculate hit rate
        total_get_ops = get_operations.size
        hit_rate = total_get_ops > 0 ? (hit_operations.size.to_f / total_get_ops * 100) : 0.0

        # Calculate average processing times
        processing_times = metrics.compact_map(&.processing_time).sort!
        avg_processing_time = processing_times.empty? ? 0.0 : processing_times.sum / processing_times.size

        # Calculate size statistics
        value_sizes = metrics.compact_map(&.value_size)
        avg_value_size = value_sizes.empty? ? 0.0 : value_sizes.sum.to_f / value_sizes.size

        {
          "total_operations"     => metrics.size.to_f,
          "get_operations"       => get_operations.size.to_f,
          "set_operations"       => set_operations.size.to_f,
          "delete_operations"    => delete_operations.size.to_f,
          "error_operations"     => error_operations.size.to_f,
          "hit_operations"       => hit_operations.size.to_f,
          "miss_operations"      => miss_operations.size.to_f,
          "hit_rate"             => hit_rate,
          "error_rate"           => (error_operations.size.to_f / metrics.size * 100),
          "avg_processing_time"  => avg_processing_time,
          "min_processing_time"  => processing_times.first? || 0.0,
          "max_processing_time"  => processing_times.last? || 0.0,
          "avg_value_size_bytes" => avg_value_size,
          "total_data_written"   => set_operations.compact_map(&.value_size).sum.to_f,
        }
      end
    end

    # Get cache operation breakdown by operation type
    def cache_operation_breakdown(since : Time? = nil) : Hash(String, Hash(String, Float64))
      since ||= @start_time

      MUTEX.synchronize do
        metrics = @cache_metrics.select { |m| m.timestamp >= since }
        breakdown = Hash(String, Hash(String, Float64)).new

        # Group by operation type
        operations = ["get", "set", "delete", "exists", "clear", "increment", "decrement"]

        operations.each do |operation|
          op_metrics = metrics.select { |m| m.operation == operation }
          next if op_metrics.empty?

          processing_times = op_metrics.map(&.processing_time).sort!
          error_count = op_metrics.count { |m| !m.successful? }

          operation_stats = {
            "count"       => op_metrics.size.to_f,
            "error_count" => error_count.to_f,
            "error_rate"  => (error_count.to_f / op_metrics.size * 100),
            "avg_time"    => processing_times.sum / processing_times.size,
            "min_time"    => processing_times.first,
            "max_time"    => processing_times.last,
          }

          # Add hit rate for get operations
          if operation == "get"
            hits = op_metrics.count(&.hit?)
            misses = op_metrics.count(&.miss?)
            total_with_result = hits + misses
            operation_stats["hit_rate"] = total_with_result > 0 ? (hits.to_f / total_with_result * 100) : 0.0
          end

          # Add data size for set operations
          if operation == "set"
            value_sizes = op_metrics.compact_map(&.value_size)
            operation_stats["avg_value_size"] = value_sizes.empty? ? 0.0 : value_sizes.sum.to_f / value_sizes.size
            operation_stats["total_data_written"] = value_sizes.sum.to_f
          end

          breakdown[operation] = operation_stats
        end

        breakdown
      end
    end

    # Get recent request metrics
    def recent_requests(limit : Int32 = 100) : Array(RequestMetric)
      MUTEX.synchronize do
        @request_metrics.last(limit)
      end
    end

    # Get recent component metrics
    def recent_components(limit : Int32 = 100) : Array(ComponentMetric)
      MUTEX.synchronize do
        @component_metrics.last(limit)
      end
    end

    # Get recent cache metrics
    def recent_caches(limit : Int32 = 100) : Array(CacheMetric)
      MUTEX.synchronize do
        @cache_metrics.last(limit)
      end
    end

    # Clear all metrics
    def clear
      MUTEX.synchronize do
        @request_metrics.clear
        @component_metrics.clear
        @cache_metrics.clear
        @error_counts.clear
        @cache_error_counts.clear
        @cache_operation_counts.clear
        @cache_hit_counts.clear
        @cache_miss_counts.clear
        @endpoint_stats.clear
        @start_time = Time.utc
      end
    end

    # Export metrics to JSON
    def to_json(io : IO) : Nil
      # Get all data first without holding locks (avoid deadlock)
      stats = aggregate_stats
      recent_req = recent_requests(50)
      recent_comp = recent_components(50)
      recent_cache = recent_caches(50)
      cache_st = cache_stats
      cache_br = cache_operation_breakdown

      endpoint_br = Hash(String, Hash(String, Float64)).new
      MUTEX.synchronize do
        @endpoint_stats.keys.each do |endpoint|
          endpoint_br[endpoint] = endpoint_stats(endpoint)
        end
      end

      {
        stats:              stats,
        recent_requests:    recent_req,
        recent_components:  recent_comp,
        recent_caches:      recent_cache,
        cache_stats:        cache_st,
        cache_breakdown:    cache_br,
        endpoint_breakdown: endpoint_br,
      }.to_json(io)
    end

    # Get current memory usage
    def self.current_memory_usage : Int64
      GC.stats.heap_size.to_i64
    end

    # Helper method to time and record cache operations
    def self.time_cache_operation(metrics : PerformanceMetrics, key : String,
                                  operation : String, store_type : String,
                                  key_size : Int32 = 0, value_size : Int32? = nil,
                                  ttl : Time::Span? = nil, &block)
      start_time = Time.monotonic
      error_message : String? = nil
      hit : Bool? = nil
      result = nil

      begin
        result = yield
        # Determine hit/miss for get operations
        if operation == "get"
          hit = !result.nil?
        end
      rescue ex
        error_message = ex.message || ex.class.name
        raise ex
      ensure
        processing_time = (Time.monotonic - start_time).total_milliseconds
        metrics.record_cache(
          key: key,
          operation: operation,
          store_type: store_type,
          processing_time: processing_time,
          hit: hit,
          key_size: key_size,
          value_size: value_size,
          ttl: ttl,
          error: error_message
        )
      end

      result
    end

    private def percentile(sorted_array : Array(Float64), percentile : Float64) : Float64
      return 0.0 if sorted_array.empty?
      return sorted_array.first if sorted_array.size == 1

      index = (percentile * (sorted_array.size - 1)).to_i
      sorted_array[index]
    end
  end
end
