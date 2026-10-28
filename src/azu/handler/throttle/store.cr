module Azu
  module Handler
    class Throttle
      # The limits a `Store` counts against: `threshold` requests per `interval` seconds, then `duration` seconds blocked.
      record Limits, interval : Int32, duration : Int32, threshold : Int32

      # What a store answers for one request: nil `retry_after` lets it through; seconds otherwise. `event` names
      # what changed for the client, for the handler's log (a store that cannot tell, such as Redis for a release, answers nil).
      record Verdict, retry_after : Int32? = nil, event : Event? = nil do
        enum Event
          Blocked
          Released
        end

        def blocked? : Bool
          !@retry_after.nil?
        end
      end

      # Where `Throttle` keeps its counters (Strategy): in the memory of the process (`Store::Memory`, the default: each
      # instance of a scaled deployment counts on its own) or in Redis (`Store::Redis`: every instance counts together).
      abstract class Store
        # Counts one request of *key* under *limits* and says whether it passes.
        abstract def hit(key : String, limits : Limits) : Verdict

        # Forgets every client; for specs and operators.
        abstract def reset : Nil

        # Clients tracked and blocked, where the store can tell (`Store::Redis` answers zeros).
        def stats : NamedTuple(tracked_ips: Int32, blocked_ips: Int32)
          {tracked_ips: 0, blocked_ips: 0}
        end

        # The store `THROTTLE_STORE` names: `redis` (`THROTTLE_REDIS_URL`, then `REDIS_URL`), `memory`, or unset
        # (memory). Anything else raises `ArgumentError`: a typo must not quietly fall back to counting per process.
        def self.from_env(max_clients : Int32 = DEFAULT_MAX_CLIENTS) : Store
          case name = ENV["THROTTLE_STORE"]?.try(&.strip.downcase).presence
          when "redis"       then Redis.from_env
          when "memory", nil then Memory.new(max_clients)
          else                    raise ArgumentError.new("THROTTLE_STORE is #{name.inspect}: use redis or memory")
          end
        end
      end
    end
  end
end
