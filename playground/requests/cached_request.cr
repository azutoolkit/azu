require "../../src/azu"

module ExampleApp
  # Request for cached endpoint
  struct CachedRequest
    include Azu::Request

    getter key : String

    def initialize(@key : String)
    end
  end

  # Request for counter endpoint
  struct CounterRequest
    include Azu::Request

    getter action : String
    getter key : String

    def initialize(@action : String, @key : String)
    end
  end

  # Request for cache stats endpoint
  struct CacheStatsRequest
    include Azu::Request

    def initialize
    end
  end

  # Request for cache management endpoint
  struct CacheManagementRequest
    include Azu::Request

    getter action : String
    getter key : String?

    def initialize(@action : String, @key : String? = nil)
    end
  end
end
