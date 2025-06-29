require "../spec_helper"

describe Azu::PerformanceMetrics do
  describe "cache metrics" do
    it "records cache operations correctly" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_cache(
        key: "test:key",
        operation: "get",
        store_type: "memory",
        processing_time: 1.5,
        hit: true,
        key_size: 8,
        value_size: 128,
        ttl: Time::Span.new(minutes: 10)
      )

      recent = metrics.recent_caches(1)
      recent.size.should eq(1)

      cache_metric = recent.first
      cache_metric.key.should eq("test:key")
      cache_metric.operation.should eq("get")
      cache_metric.store_type.should eq("memory")
      cache_metric.processing_time.should eq(1.5)
      cache_metric.hit?.should be_true
      cache_metric.key_size.should eq(8)
      cache_metric.value_size.should eq(128)
      cache_metric.successful?.should be_true
    end

    it "tracks cache hits and misses correctly" do
      metrics = Azu::PerformanceMetrics.new
      # Record some hits
      3.times do |i|
        metrics.record_cache(
          key: "key:#{i}",
          operation: "get",
          store_type: "memory",
          processing_time: 1.0,
          hit: true
        )
      end

      # Record some misses
      2.times do |i|
        metrics.record_cache(
          key: "missing:#{i}",
          operation: "get",
          store_type: "memory",
          processing_time: 0.5,
          hit: false
        )
      end

      stats = metrics.cache_stats
      stats["total_operations"].should eq(5.0)
      stats["get_operations"].should eq(5.0)
      stats["hit_operations"].should eq(3.0)
      stats["miss_operations"].should eq(2.0)
      stats["hit_rate"].should eq(60.0)
    end

    it "tracks errors correctly" do
      metrics = Azu::PerformanceMetrics.new
      # Record successful operation
      metrics.record_cache(
        key: "success:key",
        operation: "set",
        store_type: "memory",
        processing_time: 2.0
      )

      # Record failed operation
      metrics.record_cache(
        key: "error:key",
        operation: "set",
        store_type: "memory",
        processing_time: 5.0,
        error: "Connection failed"
      )

      stats = metrics.cache_stats
      stats["total_operations"].should eq(2.0)
      stats["error_operations"].should eq(1.0)
      stats["error_rate"].should eq(50.0)

      # Check error is recorded correctly
      recent = metrics.recent_caches(2)
      error_metric = recent.last
      error_metric.successful?.should be_false
      error_metric.error.should eq("Connection failed")
    end

    it "calculates operation breakdown correctly" do
      metrics = Azu::PerformanceMetrics.new
      # Record various operations
      metrics.record_cache("key1", "get", "memory", 1.0, hit: true)
      metrics.record_cache("key2", "get", "memory", 2.0, hit: false)
      metrics.record_cache("key3", "set", "memory", 3.0, value_size: 100)
      metrics.record_cache("key4", "delete", "memory", 1.5)
      metrics.record_cache("key5", "set", "memory", 4.0, value_size: 200, error: "Failed")

      breakdown = metrics.cache_operation_breakdown

      # Check GET operations
      get_stats = breakdown["get"]
      get_stats["count"].should eq(2.0)
      get_stats["hit_rate"].should eq(50.0)
      get_stats["avg_time"].should eq(1.5)
      get_stats["error_rate"].should eq(0.0)

      # Check SET operations
      set_stats = breakdown["set"]
      set_stats["count"].should eq(2.0)
      set_stats["avg_value_size"].should eq(150.0)
      set_stats["total_data_written"].should eq(300.0)
      set_stats["error_rate"].should eq(50.0)

      # Check DELETE operations
      delete_stats = breakdown["delete"]
      delete_stats["count"].should eq(1.0)
      delete_stats["avg_time"].should eq(1.5)
    end

    it "filters stats by store type" do
      metrics = Azu::PerformanceMetrics.new
      # Record operations for different stores
      metrics.record_cache("key1", "get", "memory", 1.0, hit: true)
      metrics.record_cache("key2", "get", "redis", 2.0, hit: false)
      metrics.record_cache("key3", "set", "memory", 3.0)

      memory_stats = metrics.cache_stats(store_type: "memory")
      memory_stats["total_operations"].should eq(2.0)
      memory_stats["hit_rate"].should eq(100.0)

      redis_stats = metrics.cache_stats(store_type: "redis")
      redis_stats["total_operations"].should eq(1.0)
      redis_stats["hit_rate"].should eq(0.0)
    end

    it "includes cache metrics in JSON export" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_cache("test:key", "get", "memory", 1.5, hit: true)
      metrics.record_cache("test:key2", "set", "memory", 2.0, value_size: 100)

      json_string = String.build do |io|
        metrics.to_json(io)
      end

      json_string.should contain("recent_caches")
      json_string.should contain("cache_stats")
      json_string.should contain("cache_breakdown")
      json_string.should contain("test:key")
    end

    it "respects the enabled flag" do
      metrics = Azu::PerformanceMetrics.new
      metrics.enabled = false

      metrics.record_cache("disabled", "get", "memory", 1.0)

      stats = metrics.cache_stats
      stats.should be_empty
    end

    it "clears all cache metrics" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_cache("key1", "get", "memory", 1.0)
      metrics.record_cache("key2", "set", "memory", 2.0)

      stats = metrics.cache_stats
      stats["total_operations"].should eq(2.0)

      metrics.clear

      cleared_stats = metrics.cache_stats
      cleared_stats.should be_empty
      metrics.recent_caches.should be_empty
    end

    describe "time_cache_operation helper" do
      it "times and records operations automatically" do
        metrics = Azu::PerformanceMetrics.new
        result = Azu::PerformanceMetrics.time_cache_operation(
          metrics, "helper:key", "get", "memory", key_size: 10
        ) do
          "cached_value"
        end

        result.should eq("cached_value")

        recent = metrics.recent_caches(1)
        recent.size.should eq(1)

        metric = recent.first
        metric.key.should eq("helper:key")
        metric.operation.should eq("get")
        metric.hit?.should be_true
        metric.processing_time.should be > 0.0
      end

      it "records nil results as cache misses" do
        metrics = Azu::PerformanceMetrics.new
        result = Azu::PerformanceMetrics.time_cache_operation(
          metrics, "miss:key", "get", "memory"
        ) do
          nil
        end

        result.should be_nil

        recent = metrics.recent_caches(1)
        metric = recent.first
        metric.miss?.should be_true
      end

      it "records errors correctly via helper method" do
        metrics = Azu::PerformanceMetrics.new

        # Manually record an error first to verify that works
        metrics.record_cache("manual:error", "get", "memory", 1.0, error: "Manual error")
        manual_metric = metrics.recent_caches(1).first
        manual_metric.error.should eq("Manual error")
        manual_metric.successful?.should be_false

        # Clear to test helper method
        metrics.clear

        expect_raises(Exception, "Test error") do
          Azu::PerformanceMetrics.time_cache_operation(
            metrics, "error:key", "get", "memory"
          ) do
            raise "Test error"
          end
        end

        recent = metrics.recent_caches(1)
        recent.size.should eq(1)
        metric = recent.first
        metric.error.should eq("Test error")
        metric.successful?.should be_false
      end
    end
  end
end
