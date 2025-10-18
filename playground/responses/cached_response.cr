require "../../src/azu"

# Response for cached endpoint
struct CachedResponse
  include Azu::Response

  getter key : String
  getter data : String
  getter? cached : Bool

  def initialize(@key : String, @data : String, @cached : Bool)
  end

  def render : String
    {
      "key"        => key,
      "data"       => JSON.parse(data),
      "cached"     => cached?,
      "timestamp"  => Time.utc.to_unix,
      "cache_info" => {
        "hit"    => cached?,
        "source" => cached? ? "cache" : "generated",
      },
    }.to_json
  end
end

# Response for counter endpoint
struct CounterResponse
  include Azu::Response

  getter key : String
  getter count : Int32
  getter action : String

  def initialize(@key : String, @count : Int32, @action : String)
  end

  def render : String
    {
      "key"       => key,
      "count"     => count,
      "action"    => action,
      "timestamp" => Time.utc.to_unix,
    }.to_json
  end
end

# Response for cache stats endpoint
struct CacheStatsResponse
  include Azu::Response

  getter stats : Hash(String, Int32 | Float64 | String)

  def initialize(@stats : Hash(String, Int32 | Float64 | String))
  end

  def render : String
    {
      "cache_stats" => stats,
      "timestamp"   => Time.utc.to_unix,
    }.to_json
  end
end

# Response for cache management endpoint
struct CacheManagementResponse
  include Azu::Response

  getter action : String
  getter? success : Bool
  getter message : String
  getter key : String?

  def initialize(@action : String, @success : Bool, @message : String, @key : String? = nil)
  end

  def render : String
    response = {
      "action"    => action,
      "success"   => success?,
      "message"   => message,
      "timestamp" => Time.utc.to_unix,
    }

    if k = key
      response["key"] = k
    end

    response.to_json
  end
end
