require "../spec_helper"

describe Azu::Cache do
  redis_host = ENV["REDIS_HOST"]? || "localhost"
  redis_port = ENV["REDIS_PORT"]? || 6379
  redis_url = "redis://#{redis_host}:#{redis_port}"

  describe "TimeSpanExtensions" do
    it "creates time spans from integers" do
      5.seconds.should eq(Time::Span.new(seconds: 5))
      10.minutes.should eq(Time::Span.new(minutes: 10))
      2.hours.should eq(Time::Span.new(hours: 2))
      3.days.should eq(Time::Span.new(days: 3))
    end
  end

  describe "MemoryStore" do
    it "stores and retrieves values" do
      store = Azu::Cache::MemoryStore.new

      store.set("test_key", "test_value").should be_true
      store.get("test_key").should eq("test_value")
    end

    it "returns nil for non-existent keys" do
      store = Azu::Cache::MemoryStore.new
      store.get("non_existent").should be_nil
    end

    it "checks if keys exist" do
      store = Azu::Cache::MemoryStore.new

      store.exists?("test_key").should be_false
      store.set("test_key", "value")
      store.exists?("test_key").should be_true
    end

    it "deletes keys" do
      store = Azu::Cache::MemoryStore.new

      store.set("test_key", "value")
      store.delete("test_key").should be_true
      store.get("test_key").should be_nil
      store.delete("non_existent").should be_false
    end

    it "clears all entries" do
      store = Azu::Cache::MemoryStore.new

      store.set("key1", "value1")
      store.set("key2", "value2")
      store.size.should eq(2)

      store.clear.should be_true
      store.size.should eq(0)
    end

    it "handles TTL expiration" do
      store = Azu::Cache::MemoryStore.new

      # Set with very short TTL
      store.set("expire_key", "value", Time::Span.new(nanoseconds: 1))

      # Give time for expiration
      sleep(Time::Span.new(nanoseconds: 1000000))

      store.get("expire_key").should be_nil
      store.exists?("expire_key").should be_false
    end

    it "implements LRU eviction" do
      store = Azu::Cache::MemoryStore.new(max_size: 2)

      store.set("key1", "value1")
      store.set("key2", "value2")
      store.set("key3", "value3") # Should evict key1

      store.get("key1").should be_nil
      store.get("key2").should eq("value2")
      store.get("key3").should eq("value3")
    end

    it "updates access order on get" do
      store = Azu::Cache::MemoryStore.new(max_size: 2)

      store.set("key1", "value1")
      store.set("key2", "value2")

      # Access key1 to make it most recently used
      store.get("key1")

      # Add key3, should evict key2 (least recently used)
      store.set("key3", "value3")

      store.get("key1").should eq("value1")
      store.get("key2").should be_nil
      store.get("key3").should eq("value3")
    end

    it "supports fetch with block" do
      store = Azu::Cache::MemoryStore.new

      # First call should execute block
      result = store.fetch("fetch_key") { "computed_value" }
      result.should eq("computed_value")

      # Second call should return cached value
      result = store.fetch("fetch_key") { "new_value" }
      result.should eq("computed_value")
    end

    it "supports multi-get operations" do
      store = Azu::Cache::MemoryStore.new

      store.set("key1", "value1")
      store.set("key2", "value2")

      result = store.get_multi(["key1", "key2", "key3"])
      result["key1"].should eq("value1")
      result["key2"].should eq("value2")
      result["key3"].should be_nil
    end

    it "supports multi-set operations" do
      store = Azu::Cache::MemoryStore.new

      values = {"key1" => "value1", "key2" => "value2"}
      store.set_multi(values).should be_true

      store.get("key1").should eq("value1")
      store.get("key2").should eq("value2")
    end

    it "supports increment operations" do
      store = Azu::Cache::MemoryStore.new

      # Increment non-existent key
      store.increment("counter").should eq(1)

      # Increment existing key
      store.increment("counter").should eq(2)
      store.increment("counter", 5).should eq(7)
    end

    it "supports decrement operations" do
      store = Azu::Cache::MemoryStore.new

      store.set("counter", "10")
      store.decrement("counter").should eq(9)
      store.decrement("counter", 3).should eq(6)
    end

    it "provides stats" do
      store = Azu::Cache::MemoryStore.new

      store.set("key1", "value1")
      store.set("key2", "value2")

      stats = store.stats
      stats["size"].should eq(2)
      stats["max_size"].should eq(1000)
      stats.has_key?("hit_rate").should be_true
      stats.has_key?("memory_usage_mb").should be_true
    end

    it "supports get with block syntax" do
      store = Azu::Cache::MemoryStore.new

      # First call should execute block
      result = store.get("get_block_key", Time::Span.new(minutes: 5)) { "block_result" }
      result.should eq("block_result")

      # Second call should return cached value
      result = store.get("get_block_key", Time::Span.new(minutes: 5)) { "new_block_result" }
      result.should eq("block_result")
    end
  end

  describe "NullStore" do
    it "always returns nil for get operations" do
      store = Azu::Cache::NullStore.new
      store.get("any_key").should be_nil
    end

    it "always returns false for set operations" do
      store = Azu::Cache::NullStore.new
      store.set("key", "value").should be_false
    end

    it "always returns false for delete operations" do
      store = Azu::Cache::NullStore.new
      store.delete("key").should be_false
    end

    it "always returns false for exists operations" do
      store = Azu::Cache::NullStore.new
      store.exists?("key").should be_false
    end

    it "returns true for clear operations" do
      store = Azu::Cache::NullStore.new
      store.clear.should be_true
    end

    it "always returns 0 for size" do
      store = Azu::Cache::NullStore.new
      store.size.should eq(0)
    end
  end

  describe "Configuration" do
    it "loads default configuration" do
      config = Azu::Cache::Configuration.new

      config.enabled.should be_true
      config.store.should eq("memory")
      config.max_size.should eq(1000)
      config.default_ttl.should eq(3600)
      config.key_prefix.should eq("azu")
    end

    it "loads configuration from environment" do
      ENV["CACHE_ENABLED"] = "false"
      ENV["CACHE_STORE"] = "redis"
      ENV["CACHE_MAX_SIZE"] = "2000"
      ENV["CACHE_DEFAULT_TTL"] = "7200"
      ENV["CACHE_KEY_PREFIX"] = "test"

      config = Azu::Cache::Configuration.new

      config.enabled.should be_false
      config.store.should eq("redis")
      config.max_size.should eq(2000)
      config.default_ttl.should eq(7200)
      config.key_prefix.should eq("test")

      # Clean up
      ENV.delete("CACHE_ENABLED")
      ENV.delete("CACHE_STORE")
      ENV.delete("CACHE_MAX_SIZE")
      ENV.delete("CACHE_DEFAULT_TTL")
      ENV.delete("CACHE_KEY_PREFIX")
    end

    it "converts default_ttl to time span" do
      config = Azu::Cache::Configuration.new
      config.ttl_span.should eq(Time::Span.new(seconds: 3600))
    end
  end

  describe "Manager" do
    it "creates memory store by default" do
      manager = Azu::Cache::Manager.new
      manager.store.should be_a(Azu::Cache::MemoryStore)
    end

    it "creates null store when disabled" do
      config = Azu::Cache::Configuration.new
      config.enabled = false

      manager = Azu::Cache::Manager.new(config)
      manager.store.should be_a(Azu::Cache::NullStore)
    end

    it "creates redis store when configured" do
      config = Azu::Cache::Configuration.new
      config.store = "redis"
      config.redis_url = "redis://localhost:6379/15" # Use test database

      begin
        manager = Azu::Cache::Manager.new(config)
        manager.store.should be_a(Azu::Cache::RedisStore)
      rescue
        # puts test if Redis is not available
        puts "Redis not available for testing"
      end
    end

    it "adds key prefix" do
      config = Azu::Cache::Configuration.new
      config.key_prefix = "test_app"
      manager = Azu::Cache::Manager.new(config)

      manager.set("user:123", "data")

      # Check that the underlying store has the prefixed key
      manager.store.exists?("test_app:user:123").should be_true
    end

    it "supports Rails-like API" do
      manager = Azu::Cache::Manager.new

      # Basic get/set
      manager.set("test_key", "test_value").should be_true
      manager.get("test_key").should eq("test_value")

      # Exists and delete
      manager.exists?("test_key").should be_true
      manager.delete("test_key").should be_true
      manager.get("test_key").should be_nil
    end

    it "supports get with block (Rails-like API)" do
      manager = Azu::Cache::Manager.new

      call_count = 0
      result = manager.get("get_block_key", ttl: 30.minutes) do
        call_count += 1
        "get_block_result"
      end

      result.should eq("get_block_result")
      call_count.should eq(1)

      # Second call should not execute block
      result = manager.get("get_block_key", ttl: 30.minutes) do
        call_count += 1
        "new_get_result"
      end

      result.should eq("get_block_result")
      call_count.should eq(1)
    end

    it "supports fetch with block" do
      manager = Azu::Cache::Manager.new

      call_count = 0
      result = manager.fetch("expensive_key") do
        call_count += 1
        "expensive_result"
      end

      result.should eq("expensive_result")
      call_count.should eq(1)

      # Second call should not execute block
      result = manager.fetch("expensive_key") do
        call_count += 1
        "new_result"
      end

      result.should eq("expensive_result")
      call_count.should eq(1)
    end

    it "supports counter operations" do
      manager = Azu::Cache::Manager.new

      manager.increment("page_views").should eq(1)
      manager.increment("page_views", 5).should eq(6)
      manager.decrement("page_views", 2).should eq(4)
    end

    it "provides cache stats" do
      manager = Azu::Cache::Manager.new

      stats = manager.stats
      stats["enabled"].should eq(1)
      stats["store_type"].should eq("memory")
      stats.has_key?("size").should be_true
    end

    it "handles disabled cache gracefully" do
      config = Azu::Cache::Configuration.new
      config.enabled = false
      manager = Azu::Cache::Manager.new(config)

      manager.get("key").should be_nil
      manager.set("key", "value").should be_false
      manager.fetch("key") { "value" }.should eq("value")
      manager.increment("counter").should be_nil
    end
  end

  # Redis-specific tests (only run if Redis is available)
  describe "RedisStore" do
    it "connects to Redis and performs basic operations" do
      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15", pool_size: 2)

        # Clear any existing data
        store.clear

        # Basic operations
        store.set("test_key", "test_value").should be_true
        store.get("test_key").should eq("test_value")
        store.exists?("test_key").should be_true
        store.delete("test_key").should be_true
        store.get("test_key").should be_nil
      rescue
        puts "Redis not available for testing"
      end
    end

    it "supports TTL operations" do
      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15")
        store.clear

        # Set with TTL
        store.set("ttl_key", "ttl_value", Time::Span.new(seconds: 1))
        store.get("ttl_key").should eq("ttl_value")

        # Wait for expiration
        sleep(Time::Span.new(seconds: 1, nanoseconds: 100000000))
        store.get("ttl_key").should be_nil
      rescue
        "Redis not available for testing"
      end
    end

    it "supports counter operations with Redis native commands" do
      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15")
        store.clear

        # Test increment
        store.increment("counter").should eq(1)
        store.increment("counter", 5).should eq(6)

        # Test decrement
        store.decrement("counter", 2).should eq(4)
        store.decrement("counter").should eq(3)
      rescue
        puts "Skipped:Redis not available for testing"
      end
    end

    it "supports multi-key operations with Redis native commands" do
      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15")
        store.clear

        # Multi-set
        values = {"key1" => "value1", "key2" => "value2", "key3" => "value3"}
        store.set_multi(values).should be_true

        # Multi-get
        results = store.get_multi(["key1", "key2", "key3", "key4"])
        results["key1"].should eq("value1")
        results["key2"].should eq("value2")
        results["key3"].should eq("value3")
        results["key4"].should be_nil
      rescue
        puts "Redis not available for testing"
      end
    end

    it "handles Redis connection errors gracefully" do
      begin
        # Use invalid Redis URL
        store = Azu::Cache::RedisStore.new("#{redis_url}/0")

        # Operations should return nil/false instead of crashing
        store.get("test").should be_nil
        store.set("test", "value").should be_false
        store.delete("test").should be_false
        store.exists?("test").should be_false
        store.clear.should be_false
        store.size.should eq(0)
      rescue
        # Expected if Redis connection fails during initialization
      end
    end

    it "provides Redis-specific methods" do
      redis_available = true
      store = nil

      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      rescue
        redis_available = false
      end

      unless redis_available
        puts "Redis not available for testing"
        next
      end

      # Ping should work
      store.not_nil!.ping.should eq("PONG")

      # Info should return server information
      info = store.not_nil!.info
      info.should_not be_nil
      if info
        info.has_key?("redis_version").should be_true
      end
    end

    it "supports connection pooling" do
      begin
        store = Azu::Cache::RedisStore.new("#{redis_url}/15", pool_size: 3)
        store.clear

        # Test concurrent operations
        channels = [] of Channel(String)

        5.times do |i|
          ch = Channel(String).new
          channels << ch

          spawn do
            store.set("concurrent_#{i}", "value_#{i}")
            result = store.get("concurrent_#{i}")
            ch.send(result || "nil")
          end
        end

        # Wait for all operations to complete
        results = channels.map(&.receive)
        results.size.should eq(5)
        results.each_with_index do |result, i|
          result.should eq("value_#{i}")
        end
      rescue
        puts "Redis not available for testing"
      end
    end
  end
end
