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
      with_fake_clock do |clock|
        store = Azu::Cache::MemoryStore.new
        store.set("expire_key", "value", 1.second)
        store.get("expire_key").should eq("value")

        clock.advance(1.second + 1.millisecond)

        store.get("expire_key").should be_nil
        store.exists?("expire_key").should be_false
      end
    end

    it "measures TTL on the monotonic clock, so a wall-clock step does not change expiry" do
      with_fake_clock do |clock|
        store = Azu::Cache::MemoryStore.new
        store.set("key", "value", 1.minute)

        clock.step_wall_clock(2.hours)
        store.get("key").should eq("value")

        clock.step_wall_clock(-5.hours)
        clock.advance(61.seconds)
        store.get("key").should be_nil
      end
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

    it "keeps the expiry set when the counter was created" do
      with_fake_clock do |clock|
        store = Azu::Cache::MemoryStore.new
        store.increment("hits", 1, 150.milliseconds)

        2.times do
          clock.advance(60.milliseconds)
          store.increment("hits")
        end
        clock.advance(60.milliseconds)

        store.increment("hits").should eq(1)
      end
    end

    it "evicts the least recently used key when a counter would exceed max_size" do
      store = Azu::Cache::MemoryStore.new(max_size: 2)

      5.times { |i| store.increment("counter_#{i}") }

      store.size.should eq(2)
      store.exists?("counter_0").should be_false
      store.exists?("counter_4").should be_true
    end

    it "reports the hit rate of the lookups it served" do
      store = Azu::Cache::MemoryStore.new
      store.stats["hit_rate"].should eq(0.0)

      store.set("a", "1")
      store.get("a")
      store.get("a")
      store.get("a")
      store.get("missing")

      store.stats["hit_rate"].should eq(75.0)
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

    it "supports fetch with block syntax" do
      store = Azu::Cache::MemoryStore.new

      # First call should execute block
      result = store.fetch("fetch_block_key", Time::Span.new(minutes: 5)) { "block_result" }
      result.should eq("block_result")

      # Second call should return cached value
      result = store.fetch("fetch_block_key", Time::Span.new(minutes: 5)) { "new_block_result" }
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

      config.enabled?.should be_true
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

      config.enabled?.should be_false
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
      config.redis_url = "#{redis_url}/15" # Use test database

      manager = Azu::Cache::Manager.new(config)
      manager.store.should be_a(Azu::Cache::RedisStore)
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

  # Redis-specific tests: pending when no Redis answers on REDIS_HOST:REDIS_PORT, never silently passing.
  describe "RedisStore" do
    redis_up = begin
      TCPSocket.new(redis_host, redis_port.to_i, connect_timeout: 0.5.seconds).close
      true
    rescue Socket::Error | IO::Error
      false
    end

    before_each do
      pending!("Redis is not reachable at #{redis_url}") unless redis_up
    end

    it "connects to Redis and performs basic operations" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15", pool_size: 2)
      store.clear.should be_true

      store.set("test_key", "test_value").should be_true
      store.get("test_key").should eq("test_value")
      store.exists?("test_key").should be_true
      store.delete("test_key").should be_true
      store.get("test_key").should be_nil
      store.exists?("test_key").should be_false
    end

    it "supports TTL operations" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      store.clear

      store.set("ttl_key", "ttl_value", Time::Span.new(seconds: 1))
      store.get("ttl_key").should eq("ttl_value")

      sleep(Time::Span.new(seconds: 1, nanoseconds: 100000000))
      store.get("ttl_key").should be_nil
    end

    it "supports counter operations with Redis native commands" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      store.clear

      store.increment("counter").should eq(1)
      store.increment("counter", 5).should eq(6)
      store.decrement("counter", 2).should eq(4)
      store.decrement("counter").should eq(3)
    end

    it "sets a counter's expiry once, when the counter has none, and never renews it" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      store.clear

      store.increment("hits", 1, 100.seconds).should eq(1)
      store.increment("hits", 1, 5.seconds).should eq(2)
      store.decrement("hits", 1, 5.seconds).should eq(1)
      ttl = Redis.new(url: "#{redis_url}/15").ttl("hits")
      ttl.should be > 50

      store.increment("existing_counter", 3) # created without an expiry
      store.increment("existing_counter", 1, 100.seconds).should eq(4)
      Redis.new(url: "#{redis_url}/15").ttl("existing_counter").should be > 0

      store.decrement("fresh", 2, 100.seconds).should eq(-2)
      Redis.new(url: "#{redis_url}/15").ttl("fresh").should be > 0
    end

    it "supports multi-key operations with Redis native commands" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      store.clear

      store.set_multi({"key1" => "value1", "key2" => "value2", "key3" => "value3"}).should be_true

      results = store.get_multi(["key1", "key2", "key3", "key4"])
      results["key1"].should eq("value1")
      results["key2"].should eq("value2")
      results["key3"].should eq("value3")
      results["key4"].should be_nil
    end

    it "counts its keys" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")
      store.clear
      store.set("a", "1")
      store.set("b", "2")

      store.size.should eq(2)
    end

    it "answers ping and info" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15")

      store.ping.should eq("PONG")
      store.info.not_nil!.has_key?("redis_version").should be_true
    end

    it "passes the connectivity check that Configuration runs at start-up" do
      config = Azu::Cache::Configuration.new
      config.store = "redis"
      config.redis_url = "#{redis_url}/15"

      manager = Azu::Cache::Manager.new(config)
      manager.store.should be_a(Azu::Cache::RedisStore)
      manager.ping.should eq("PONG")
    end

    it "supports connection pooling" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15", pool_size: 3)
      store.clear

      channels = Array(Channel(String)).new(5) { Channel(String).new }
      channels.each_with_index do |ch, i|
        spawn do
          store.set("concurrent_#{i}", "value_#{i}")
          ch.send(store.get("concurrent_#{i}") || "nil")
        end
      end

      channels.map(&.receive).should eq((0...5).map { |i| "value_#{i}" })
    end

    it "gives up on a command that outlasts the operation timeout" do
      store = Azu::Cache::RedisStore.new("#{redis_url}/15", operation_timeout: 50.milliseconds)
      store.clear
      store.set("present", "value").should be_true
      store.get("present").should eq("value")

      # Keeps the server busy for ~400 ms so the next command has to wait for it
      busy = <<-LUA
        local started = redis.call('TIME')
        while true do
          local now = redis.call('TIME')
          if (now[1] - started[1]) * 1000000 + (now[2] - started[2]) > 400000 then break end
        end
        return 1
        LUA
      spawn { Redis.new(url: "#{redis_url}/15").eval(busy) }
      sleep 50.milliseconds

      started = Time.instant
      store.get("present").should be_nil
      (Time.instant - started).should be < 300.milliseconds
    end
  end

  describe "RedisStore without a server" do
    it "answers nil/false/0 instead of raising" do
      store = Azu::Cache::RedisStore.new("redis://127.0.0.1:1/0", timeout: 0.2.seconds, operation_timeout: 0.5.seconds)

      store.get("test").should be_nil
      store.set("test", "value").should be_false
      store.delete("test").should be_false
      store.exists?("test").should be_false
      store.clear.should be_false
      store.size.should eq(0)
      store.ping.should be_nil
    end
  end

  describe "Stampede Protection" do
    it "prevents cache stampede with concurrent requests" do
      manager = Azu::Cache::Manager.new
      manager.clear

      call_count = 0
      channels = [] of Channel(String)

      # Simulate 10 concurrent requests for the same missing key
      10.times do
        ch = Channel(String).new
        channels << ch

        spawn do
          result = manager.fetch("stampede_test") do
            call_count += 1
            sleep(Time::Span.new(nanoseconds: 100_000_000)) # Simulate expensive operation
            "expensive_result"
          end
          ch.send(result)
        end
      end

      # Wait for all requests to complete
      results = channels.map(&.receive)
      results.size.should eq(10)
      results.uniq.should eq(["expensive_result"])

      # Only one expensive operation should have been executed
      call_count.should eq(1)
    end

    it "allows concurrent requests for different keys" do
      manager = Azu::Cache::Manager.new
      manager.clear

      call_count = 0
      channels = [] of Channel(String)

      # Simulate concurrent requests for different keys
      5.times do |i|
        ch = Channel(String).new
        channels << ch

        spawn do
          result = manager.fetch("different_key_#{i}") do
            call_count += 1
            sleep(Time::Span.new(nanoseconds: 100_000_000)) # Simulate expensive operation
            "result_#{i}"
          end
          ch.send(result)
        end
      end

      # Wait for all requests to complete
      results = channels.map(&.receive)
      results.size.should eq(5)

      # All expensive operations should have been executed
      call_count.should eq(5)
    end
  end

  describe "MemoryStore Cleanup" do
    it "runs background cleanup task" do
      store = Azu::Cache::MemoryStore.new(cleanup_interval: Time::Span.new(nanoseconds: 100_000_000))

      # Add expired entry
      store.set("expired_key", "value", Time::Span.new(nanoseconds: 1))

      # Wait for cleanup
      sleep(Time::Span.new(nanoseconds: 200_000_000))

      # Entry should be cleaned up
      store.get("expired_key").should be_nil
      store.size.should eq(0)

      # Clean up
      store.stop_cleanup_task
    end

    it "handles cleanup task errors gracefully" do
      store = Azu::Cache::MemoryStore.new(cleanup_interval: Time::Span.new(nanoseconds: 50_000_000))

      # Add some entries
      store.set("key1", "value1")
      store.set("key2", "value2")

      # Wait for cleanup cycle
      sleep(Time::Span.new(nanoseconds: 100_000_000))

      # Store should still be functional
      store.get("key1").should eq("value1")
      store.get("key2").should eq("value2")

      # Clean up
      store.stop_cleanup_task
    end
  end

  describe "Concurrent Operations" do
    it "handles concurrent increment operations safely" do
      manager = Azu::Cache::Manager.new
      manager.clear

      channels = [] of Channel(Int32?)

      # Simulate 20 concurrent increments
      20.times do
        ch = Channel(Int32?).new
        channels << ch

        spawn do
          result = manager.increment("concurrent_counter")
          ch.send(result)
        end
      end

      # Wait for all operations to complete
      results = channels.map(&.receive)
      results.compact.size.should eq(20)

      # Final value should be 20
      final_count = manager.get("concurrent_counter").try(&.to_i) || 0
      final_count.should eq(20)
    end

    it "handles mixed concurrent operations" do
      manager = Azu::Cache::Manager.new
      manager.clear

      channels = [] of Channel(String?)

      # Mix of operations
      10.times do |i|
        ch = Channel(String?).new
        channels << ch

        spawn do
          case i % 3
          when 0
            manager.set("key_#{i}", "value_#{i}")
            result = manager.get("key_#{i}")
          when 1
            manager.increment("counter")
            result = manager.get("counter")
          else
            manager.fetch("fetch_key_#{i}") { "computed_#{i}" }
            result = manager.get("fetch_key_#{i}")
          end
          ch.send(result)
        end
      end

      # Wait for all operations to complete
      results = channels.map(&.receive)
      results.compact.size.should eq(10)
    end
  end
end
