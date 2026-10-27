module Azu
  module CQL
    # What CQL's request query cache saw during the current request: `queries` statements tracked, of which `repeated`
    # ran before in the same request with the same SQL and parameters.
    record RequestCacheStats, request_id : String, queries : Int64, repeated : Int64

    # The stats of the request being served, while `Middleware.new(query_cache: true)` tracks it; nil outside such a
    # request, and when CQL's cache or its request cache is switched off (`config.cache.on`, `config.cache.request_cache`).
    def self.request_cache_stats : RequestCacheStats?
      RequestCache.current
    end

    # :nodoc:
    #
    # Opens CQL's request cache for a request (through `::CQL.with_request_cache`, its only entry point here) and
    # remembers, per fiber, CQL's counters at the start: the stats are the difference, so they cover this request
    # whether CQL keeps its counters per request or for the whole process.
    module RequestCache
      private record Baseline, request_id : String, hits : Int64, misses : Int64

      @@mutex = Mutex.new
      @@baselines = {} of Fiber => Baseline

      def self.scope(request_id : String, &) : Nil
        ::CQL.with_request_cache(request_id) do
          next yield unless tracking?

          fiber = Fiber.current
          hits, misses = counters
          @@mutex.synchronize { @@baselines[fiber] = Baseline.new(request_id, hits, misses) }
          begin
            yield
          ensure
            @@mutex.synchronize { @@baselines.delete(fiber) }
          end
        end
      end

      def self.current : RequestCacheStats?
        baseline = @@mutex.synchronize { @@baselines[Fiber.current]? }
        return unless baseline

        hits, misses = counters
        repeated = hits - baseline.hits
        RequestCacheStats.new(baseline.request_id, repeated + misses - baseline.misses, repeated)
      end

      # The switches `::CQL.with_request_cache` honours.
      private def self.tracking? : Bool
        cache = ::CQL.config.cache
        cache.on? && cache.request_cache?
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
