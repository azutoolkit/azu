# Cache Metrics

The Azu performance metrics system includes comprehensive caching statistics to help monitor and optimize cache performance. This feature tracks cache operations, hit/miss ratios, timing data, and error rates across different cache stores.

## Overview

Cache metrics are automatically collected when using the `Azu::PerformanceMetrics` class alongside the Azu cache system. The metrics include:

- **Hit/Miss Ratios**: Track cache effectiveness
- **Operation Timing**: Monitor cache performance
- **Error Tracking**: Identify cache operation failures
- **Data Volume**: Monitor cache storage usage
- **Operation Breakdown**: Analyze specific cache operations

## Recording Cache Metrics

### Manual Recording

```crystal
metrics = Azu::PerformanceMetrics.new

# Record a cache operation manually
metrics.record_cache(
  key: "user:123",
  operation: "get",
  store_type: "memory",
  processing_time: 1.5,
  hit: true,
  key_size: 8,
  value_size: 256,
  ttl: Time::Span.new(minutes: 10)
)
```

### Automatic Timing

Use the helper method to automatically time and record operations:

```crystal
result = Azu::PerformanceMetrics.time_cache_operation(
  metrics, "user:123", "get", "memory",
  key_size: 8
) do
  cache.get("user:123")
end
```

## Cache Statistics

### Overall Cache Stats

```crystal
stats = metrics.cache_stats
puts "Hit Rate: #{stats["hit_rate"]}%"
puts "Error Rate: #{stats["error_rate"]}%"
puts "Average Processing Time: #{stats["avg_processing_time"]}ms"
```

### Operation Breakdown

```crystal
breakdown = metrics.cache_operation_breakdown
breakdown.each do |operation, op_stats|
  puts "#{operation.upcase}:"
  puts "  Count: #{op_stats["count"]}"
  puts "  Hit Rate: #{op_stats["hit_rate"]}%" if operation == "get"
  puts "  Error Rate: #{op_stats["error_rate"]}%"
end
```

### Store-Specific Stats

```crystal
# Get stats for a specific cache store
memory_stats = metrics.cache_stats(store_type: "memory")
redis_stats = metrics.cache_stats(store_type: "redis")
```

## Tracked Operations

The cache metrics system tracks the following operations:

- **get**: Cache retrieval operations (tracks hits/misses)
- **set**: Cache storage operations (tracks data volume)
- **delete**: Cache deletion operations
- **exists**: Cache existence checks
- **clear**: Cache clearing operations
- **increment**: Atomic increment operations
- **decrement**: Atomic decrement operations

## Metrics Data Structure

### CacheMetric

Each cache operation creates a `CacheMetric` with the following properties:

```crystal
struct CacheMetric
  getter key : String                # Cache key
  getter operation : String          # Operation type
  getter store_type : String         # Cache store (memory, redis, etc.)
  getter hit : Bool?                 # Hit/miss for get operations
  getter processing_time : Float64   # Operation duration in milliseconds
  getter key_size : Int32           # Key size in bytes
  getter value_size : Int32?        # Value size in bytes (for set operations)
  getter ttl : Time::Span?          # Time-to-live
  getter timestamp : Time           # When the operation occurred
  getter error : String?            # Error message if operation failed
end
```

## Integration Example

Here's a complete example of integrating cache metrics:

```crystal
require "azu"

# Initialize metrics and cache
metrics = Azu::PerformanceMetrics.new
cache_config = Azu::Cache::Configuration.new
cache = Azu::Cache::Manager.new(cache_config)

# Instrument cache operations
def instrumented_cache_get(cache, metrics, key)
  Azu::PerformanceMetrics.time_cache_operation(
    metrics, key, "get", cache.config.store, key.bytesize
  ) do
    cache.get(key)
  end
end

# Use the instrumented cache
user_data = instrumented_cache_get(cache, metrics, "user:123")

# Analyze performance
stats = metrics.cache_stats
puts "Cache hit rate: #{stats["hit_rate"]}%"
puts "Average response time: #{stats["avg_processing_time"]}ms"
```

## JSON Export

Cache metrics are included in the JSON export:

```crystal
metrics.to_json(io) # Includes cache_stats and recent_caches
```

The exported JSON includes:

- `recent_caches`: Recent cache operations
- `cache_stats`: Overall cache statistics
- `cache_breakdown`: Per-operation statistics

## Performance Considerations

- Metrics collection has minimal overhead (< 1ms per operation)
- Memory usage is bounded by `MAX_METRICS` (default: 10,000 operations)
- Old metrics are automatically evicted to prevent memory bloat
- Thread-safe for concurrent cache operations

## Best Practices

1. **Enable Selectively**: Only enable cache metrics in development or when monitoring is needed
2. **Monitor Hit Rates**: Aim for hit rates > 80% for effective caching
3. **Watch Error Rates**: Error rates > 5% may indicate cache connectivity issues
4. **Optimize Slow Operations**: Operations > 10ms may need investigation
5. **Review Data Volume**: Monitor `total_data_written` to understand cache load

## Example Output

```
📈 Cache Statistics:
Total Operations: 1250
Hit Rate: 87.5%
Error Rate: 0.8%
Average Processing Time: 2.3ms

🔧 Operation Breakdown:
GET:
  Count: 950
  Hit Rate: 87.5%
  Error Rate: 0.0%

SET:
  Count: 200
  Data Written: 50240 bytes
  Error Rate: 2.0%
```

This comprehensive cache metrics system helps identify performance bottlenecks and optimize cache configuration for better application performance.
