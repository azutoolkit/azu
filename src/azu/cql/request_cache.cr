module Azu
  module CQL
    # How often the request being served ran the same SELECT (same SQL, same parameters), as counted by
    # CQL's request query cache. `queries` = `distinct` + `repeated`.
    record RequestCacheStats, request_id : String, queries : Int64, repeated : Int64 do
      def distinct : Int64
        queries - repeated
      end
    end

    # The repeated-query counts of the current request, or nil outside a `Middleware.new(query_cache: true)`
    # request and when CQL's request cache is off (`config.cache.on` and `config.cache.request_cache`).
    def self.request_cache_stats : RequestCacheStats?
      RequestCache.stats
    end

    # Opens CQL's request query cache (`::CQL.with_request_cache`) around a request and remembers its counters
    # at the start, per fiber, so the stats are this request's share of them.
    module RequestCache
      private alias Baseline = {String, Int64, Int64} # request id, hits, misses

      @@mutex = Mutex.new
      @@baselines = {} of Fiber => Baseline

      def self.scope(request_id : String, &)
        ::CQL.with_request_cache(request_id) do
          fiber = Fiber.current
          previous = @@mutex.synchronize { @@baselines[fiber]? }
          track(fiber, request_id) if tracking?
          begin
            yield
          ensure
            @@mutex.synchronize { previous ? (@@baselines[fiber] = previous) : @@baselines.delete(fiber) }
          end
        end
      end

      def self.stats : RequestCacheStats?
        request_id, hits, misses = @@mutex.synchronize { @@baselines[Fiber.current]? } || return
        now_hits, now_misses = counters
        repeated = Math.max(now_hits - hits, 0_i64)
        RequestCacheStats.new(request_id, queries: repeated + Math.max(now_misses - misses, 0_i64), repeated: repeated)
      end

      # The condition under which `::CQL.with_request_cache` starts the tracker.
      private def self.tracking? : Bool
        cache = ::CQL.config.cache
        cache.on? && cache.request_cache?
      end

      private def self.track(fiber : Fiber, request_id : String) : Nil
        hits, misses = counters
        @@mutex.synchronize { @@baselines[fiber] = {request_id, hits, misses} }
      end

      private def self.counters : {Int64, Int64}
        stats = ::CQL::Cache::RequestQueryCacheHelper.stats
        {count(stats["hits"]?), count(stats["misses"]?)}
      end

      private def self.count(value) : Int64
        value.is_a?(Int) ? value.to_i64 : 0_i64
      end
    end
  end
end
