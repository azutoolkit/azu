require "../../src/azu"

# Demo showing cache metrics collection and analysis
class CacheMetricsDemo
  def self.run
    puts "🔍 Cache Metrics Demo"
    puts "=" * 50

    # Initialize performance metrics and cache
    metrics = Azu::PerformanceMetrics.new
    cache_config = Azu::Cache::Configuration.new
    cache_config.store = "memory"
    cache_config.max_size = 100
    cache_manager = Azu::Cache::Manager.new(cache_config)

    puts "\n📊 Simulating cache operations..."

    # Simulate various cache operations with metrics tracking
    simulate_cache_operations(metrics, cache_manager)

    puts "\n📈 Cache Statistics:"
    puts "-" * 30

    # Display overall cache stats
    stats = metrics.cache_stats
    puts "Total Operations: #{stats["total_operations"]?.try &.to_i || 0}"
    puts "Hit Rate: #{stats["hit_rate"]?.try { |hit_rate| "#{hit_rate.round(2)}%" } || "0%"}"
    puts "Error Rate: #{stats["error_rate"]?.try { |error_rate| "#{error_rate.round(2)}%" } || "0%"}"
    puts "Average Processing Time: #{stats["avg_processing_time"]?.try { |apt| "#{apt.round(3)}ms" } || "0ms"}"

    # Display operation breakdown
    puts "\n🔧 Operation Breakdown:"
    puts "-" * 30
    breakdown = metrics.cache_operation_breakdown
    breakdown.each do |operation, op_stats|
      puts "#{operation.upcase}:"
      puts "  Count: #{op_stats["count"]?.try &.to_i || 0}"
      puts "  Avg Time: #{op_stats["avg_time"]?.try { |time| "#{time.round(3)}ms" } || "0ms"}"
      puts "  Error Rate: #{op_stats["error_rate"]?.try { |error_rate| "#{error_rate.round(1)}%" } || "0%"}"

      if operation == "get" && op_stats["hit_rate"]?
        puts "  Hit Rate: #{op_stats["hit_rate"].try { |hit_rate| "#{hit_rate.round(1)}%" } || "0%"}"
      end

      if operation == "set" && op_stats["total_data_written"]?
        puts "  Data Written: #{op_stats["total_data_written"].try { |data_written| "#{data_written.to_i} bytes" } || "0 bytes"}"
      end
      puts
    end

    # Display recent cache operations
    puts "🕒 Recent Cache Operations:"
    puts "-" * 30
    recent = metrics.recent_caches(10)
    recent.each do |metric|
      status = metric.successful? ? "✅" : "❌"
      hit_info = metric.operation == "get" ? (metric.hit? ? " [HIT]" : " [MISS]") : ""
      puts "#{status} #{metric.operation.upcase} #{metric.key}#{hit_info} (#{metric.processing_time.round(3)}ms)"
    end

    puts "\n✨ Demo completed!"
  end

  private def self.simulate_cache_operations(metrics : Azu::PerformanceMetrics, cache : Azu::Cache::Manager)
    # Simulate a mix of cache operations

    # Set operations
    ["user:1", "user:2", "user:3", "session:abc", "config:app"].each do |key|
      value = "data_for_#{key}"
      time_and_record_operation(metrics, key, "set", cache.config.store, value.bytesize) do
        cache.set(key, value, Time::Span.new(minutes: 10))
      end
      sleep Time::Span.new(nanoseconds: 1_000_000) # Small delay to vary timing
    end

    # Get operations (some hits, some misses)
    ["user:1", "user:2", "user:4", "session:abc", "session:xyz", "config:app"].each do |key|
      time_and_record_operation(metrics, key, "get", cache.config.store, key.bytesize) do
        cache.get(key)
      end
      sleep Time::Span.new(nanoseconds: 1_000_000)
    end

    # Delete operations
    ["user:2", "session:abc"].each do |key|
      time_and_record_operation(metrics, key, "delete", cache.config.store, key.bytesize) do
        cache.delete(key)
      end
      sleep Time::Span.new(nanoseconds: 1_000_000)
    end

    # More get operations to show misses
    ["user:2", "session:abc"].each do |key|
      time_and_record_operation(metrics, key, "get", cache.config.store, key.bytesize) do
        cache.get(key)
      end
      sleep Time::Span.new(nanoseconds: 1_000_000)
    end

    # Simulate an error (try to increment a non-numeric value)
    begin
      time_and_record_operation(metrics, "user:1", "increment", cache.config.store, 6) do
        cache.increment("user:1") # This will error since "user:1" contains string data
      end
    rescue
      # Expected error for demo purposes
    end
  end

  private def self.time_and_record_operation(metrics : Azu::PerformanceMetrics, key : String,
                                             operation : String, store_type : String,
                                             key_size : Int32, &)
    start_time = Time.monotonic
    error = nil
    hit = nil

    begin
      result = yield
      # Determine hit/miss for get operations
      if operation == "get"
        hit = !result.nil?
      end
      result
    rescue ex
      error = ex.message
      nil # Return nil instead of re-raising for demo purposes
    ensure
      processing_time = (Time.monotonic - start_time).total_milliseconds
      value_size = operation == "set" ? 20 : nil # Approximate value size for set operations

      metrics.record_cache(
        key: key,
        operation: operation,
        store_type: store_type,
        processing_time: processing_time,
        hit: hit,
        key_size: key_size,
        value_size: value_size,
        ttl: Time::Span.new(minutes: 10),
        error: error
      )
    end
  end
end

# Run the demo if this file is executed directly
if PROGRAM_NAME.includes?("cache_metrics_demo")
  CacheMetricsDemo.run
end
