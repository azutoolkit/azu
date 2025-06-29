require "../../src/azu"
require "../requests/cached_request"
require "../responses/cached_response"

module ExampleApp
  # Example endpoint demonstrating Azu's caching capabilities
  struct CachedEndpoint
    include Azu::Endpoint(CachedRequest, CachedResponse)

    get "/cached/:key"

    def call : CachedResponse
      cache_key = cached_request.key

      # Rails-like cache.fetch with block syntax
      cached_value = Azu.cache.fetch("user_data:#{cache_key}", ttl: Time::Span.new(minutes: 5)) do
        # Simulate expensive operation
        expensive_data_operation(cache_key)
      end

      CachedResponse.new(cache_key, cached_value, cached: Azu.cache.exists?("user_data:#{cache_key}"))
    end

    private def expensive_data_operation(key : String) : String
      # Simulate expensive database query or API call
      sleep(5.seconds)
      {
        "id"                    => key,
        "name"                  => "User #{key}",
        "email"                 => "user#{key}@example.com",
        "generated_at"          => Time.utc.to_unix.to_s,
        "expensive_calculation" => Random.rand(1000..9999),
      }.to_json
    end
  end

  # Counter endpoint demonstrating increment/decrement
  struct CounterEndpoint
    include Azu::Endpoint(CounterRequest, CounterResponse)

    post "/counter/:action/:key"

    def call : CounterResponse
      key = counter_request.key
      action = counter_request.action

      case action
      when "increment"
        count = Azu.cache.increment(key, ttl: Time::Span.new(hours: 1)) || 0
      when "decrement"
        count = Azu.cache.decrement(key, ttl: Time::Span.new(hours: 1)) || 0
      when "get"
        count = Azu.cache.get(key).try(&.to_i) || 0
      when "reset"
        Azu.cache.delete(key)
        count = 0
      else
        count = 0
      end

      CounterResponse.new(key, count, action)
    end
  end

  # Cache stats endpoint
  struct CacheStatsEndpoint
    include Azu::Endpoint(CacheStatsRequest, CacheStatsResponse)

    get "/stats/cache"

    def call : CacheStatsResponse
      stats = Azu.cache.stats
      CacheStatsResponse.new(stats)
    end
  end

  # Cache management endpoint
  struct CacheManagementEndpoint
    include Azu::Endpoint(CacheManagementRequest, CacheManagementResponse)

    delete "/cache/:action"
    delete "/cache/:action/:key"

    def call : CacheManagementResponse
      action = cache_management_request.action
      key = cache_management_request.key

      case action
      when "clear"
        success = Azu.cache.clear
        CacheManagementResponse.new(action, success, "Cache cleared")
      when "delete"
        if key
          success = Azu.cache.delete(key)
          message = success ? "Key deleted" : "Key not found"
          CacheManagementResponse.new(action, success, message, key)
        else
          CacheManagementResponse.new(action, false, "Key required for delete action")
        end
      else
        CacheManagementResponse.new(action, false, "Unknown action")
      end
    end
  end

  # Example endpoint using the new get with block syntax
  struct GetWithBlockEndpoint
    include Azu::Endpoint(CachedRequest, CachedResponse)

    get "/get-block/:key"

    def call : CachedResponse
      cache_key = cached_request.key

      # Rails-like cache.get with block syntax and TTL
      cached_value = Azu.cache.get("block_user_data:#{cache_key}", ttl: Time::Span.new(minutes: 10)) do
        # This block executes only if the key is not cached
        expensive_data_operation(cache_key)
      end

      CachedResponse.new(cache_key, cached_value, cached: Azu.cache.exists?("block_user_data:#{cache_key}"))
    end

    private def expensive_data_operation(key : String) : String
      # Simulate expensive database query or API call
      sleep(5.seconds)
      {
        "id"                    => key,
        "name"                  => "User #{key}",
        "email"                 => "user#{key}@example.com",
        "generated_at"          => Time.utc.to_unix.to_s,
        "expensive_calculation" => Random.rand(1000..9999),
        "method"                => "get_with_block",
      }.to_json
    end
  end
end
