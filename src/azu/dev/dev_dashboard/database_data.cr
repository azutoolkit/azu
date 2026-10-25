module Azu
  module Components
    module Dashboard
      # Query statistics read from CQL's performance monitor.
      #
      # The CQL branches are compiled only when the `CQL` constant exists at
      # require time (require `cql` before `azu`); otherwise, and whenever the
      # monitor cannot be read, every method returns an inactive/empty result and
      # the Database tab shows its "n/a" state.
      module DatabaseData
        record DatabaseStats, active : Bool, queries : Int64, patterns : Int32,
          avg_ms : Float64, min_ms : Float64, max_ms : Float64,
          slow : Int32, very_slow : Int32, n_plus_one : Int32, critical : Int32, high : Int32 do
          # 100 minus penalties for slow queries, N+1 patterns and a high average latency.
          def health : Int32
            latency_penalty = avg_ms > 100 ? ((avg_ms - 100) / 50).to_i.clamp(0, 20) : 0
            (100 - (slow * 2).clamp(0, 30) - (n_plus_one * 5).clamp(0, 25) - latency_penalty).clamp(0, 100)
          end
        end

        record SlowQuery, sql : String, ms : Float64, rows : Int64, at : Time
        record QueryPattern, sql : String, executions : Int32, avg_ms : Float64, score : Float64
        record NPlusOneIssue, severity : String, message : String

        INACTIVE = DatabaseStats.new(false, 0_i64, 0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 0)

        @database_stats : DatabaseStats?

        def database_stats : DatabaseStats
          @database_stats ||= load_database_stats
        end

        def slow_queries(limit : Int32 = 20) : Array(SlowQuery)
          return store_slow_queries(limit) if store_active?
          {% if @top_level.has_constant?("CQL") %}
            CQL::Performance.monitor.profiler.not_nil!.slowest_queries(limit).map do |query|
              SlowQuery.new(query.sql, query.execution_time.total_milliseconds, query.rows_affected || 0_i64, query.timestamp)
            end
          {% else %}
            [] of SlowQuery
          {% end %}
        rescue ex
          @log.error { "Failed to collect slow queries: #{ex.message}" }
          [] of SlowQuery
        end

        # Most executed statement shapes first.
        def query_patterns(limit : Int32 = 15) : Array(QueryPattern)
          return store_query_patterns(limit) if store_active?
          {% if @top_level.has_constant?("CQL") %}
            patterns = CQL::Performance.monitor.profiler.not_nil!.statistics.map do |sql, stat|
              QueryPattern.new(sql, stat[:count], stat[:avg_ms], pattern_score(stat[:count], stat[:avg_ms], stat[:max_ms]))
            end
            patterns.sort_by!(&.executions).reverse!.first(limit)
          {% else %}
            [] of QueryPattern
          {% end %}
        rescue ex
          @log.error { "Failed to collect query patterns: #{ex.message}" }
          [] of QueryPattern
        end

        def n_plus_one_issues : Array(NPlusOneIssue)
          return store_n_plus_one_issues if store_active?
          {% if @top_level.has_constant?("CQL") %}
            CQL::Performance.monitor.detector.not_nil!.issues.map { |issue| NPlusOneIssue.new(issue.severity.to_s, issue.message) }
          {% else %}
            [] of NPlusOneIssue
          {% end %}
        rescue ex
          @log.error { "Failed to collect N+1 issues: #{ex.message}" }
          [] of NPlusOneIssue
        end

        # Newest first: the statements an ORM integration (`azu/cql`) recorded, with their request.
        def recent_queries(limit : Int32 = 40) : Array(QueryMetric)
          QueryStore.instance.queries(0_i64, limit).reverse
        end

        def database_transactions(limit : Int32 = 15) : Array(TransactionMetric)
          QueryStore.instance.transactions(limit)
        end

        def database_pool : PoolSnapshot?
          QueryStore.instance.pool
        end

        # The SQL playground card is shown only in development with a database attached.
        def sql_playground? : Bool
          QueryStore.instance.playground_available?
        end

        # True when an ORM integration (`azu/cql`) feeds `Azu::QueryStore`; its statements
        # take precedence over CQL's own monitor.
        def store_backed? : Bool
          QueryStore.instance.enabled?
        end

        private def store_active? : Bool
          store_backed?
        end

        private def store_queries : Array(QueryMetric)
          QueryStore.instance.queries(0_i64, QueryStore::MAX_QUERIES)
        end

        private def store_critical_threshold : Int32
          Azu.current_config.database.n_plus_one_threshold * 3
        end

        private def store_database_stats : DatabaseStats
          settings = Azu.current_config.database
          queries = store_queries
          alerts = QueryAnalysis.n_plus_one(queries, settings.n_plus_one_threshold)
          durations = queries.map(&.duration_ms)
          DatabaseStats.new(
            active: true,
            queries: queries.size.to_i64,
            patterns: queries.map(&.normalized_sql).uniq!.size,
            avg_ms: durations.empty? ? 0.0 : durations.sum / durations.size,
            min_ms: durations.min? || 0.0,
            max_ms: durations.max? || 0.0,
            slow: queries.count { |query| query.duration_ms >= settings.slow_query_ms },
            very_slow: queries.count { |query| query.duration_ms > 500 },
            n_plus_one: alerts.size,
            critical: alerts.count { |alert| alert.count >= store_critical_threshold },
            high: alerts.count { |alert| alert.count < store_critical_threshold })
        end

        private def store_slow_queries(limit : Int32) : Array(SlowQuery)
          threshold = Azu.current_config.database.slow_query_ms
          store_queries.select { |query| query.duration_ms >= threshold }
            .sort_by!(&.duration_ms).reverse!.first(limit)
            .map { |query| SlowQuery.new(query.sql, query.duration_ms, query.rows || 0_i64, Time.unix_ms(query.started_ms)) }
        end

        private def store_query_patterns(limit : Int32) : Array(QueryPattern)
          store_queries.group_by(&.normalized_sql).map do |sql, group|
            durations = group.map(&.duration_ms)
            avg = durations.sum / durations.size
            QueryPattern.new(sql, group.size, avg, pattern_score(group.size, avg, durations.max))
          end.sort_by!(&.executions).reverse!.first(limit)
        end

        private def store_n_plus_one_issues : Array(NPlusOneIssue)
          QueryAnalysis.n_plus_one(store_queries, Azu.current_config.database.n_plus_one_threshold).map do |alert|
            where = [alert.endpoint || alert.path, alert.caller].compact.join(" at ")
            hint = alert.suggestion.try { |text| ". #{text}" } || ""
            severity = alert.count >= store_critical_threshold ? "critical" : "high"
            NPlusOneIssue.new(severity, "#{alert.count}x #{alert.normalized_sql} (#{alert.total_ms.round(1)} ms) in #{where}#{hint}")
          end
        end

        private def load_database_stats : DatabaseStats
          return store_database_stats if store_active?
          {% if @top_level.has_constant?("CQL") %}
            monitor = CQL::Performance.monitor
            profiler = monitor.profiler.not_nil!
            issues = monitor.detector.not_nil!.issues
            patterns = profiler.statistics.values
            queries = patterns.sum(&.[:count]).to_i64
            slow = monitor.metrics_summary["slow_queries"]?.try(&.as(Int64)) || 0_i64

            DatabaseStats.new(
              active: monitor.enabled?,
              queries: queries,
              patterns: patterns.size,
              avg_ms: queries > 0 ? patterns.sum(&.[:total_ms]) / queries : 0.0,
              min_ms: patterns.min_of?(&.[:min_ms]) || 0.0,
              max_ms: patterns.max_of?(&.[:max_ms]) || 0.0,
              slow: slow.to_i32,
              very_slow: profiler.slowest_queries(100).count { |query| query.execution_time.total_milliseconds > 500 },
              n_plus_one: issues.size,
              critical: issues.count { |issue| issue.severity == :critical },
              high: issues.count { |issue| issue.severity == :high })
          {% else %}
            INACTIVE
          {% end %}
        rescue ex
          @log.error { "Failed to collect database metrics: #{ex.message}" }
          INACTIVE
        end

        # 100 minus penalties for frequent, slow and spiky statements.
        private def pattern_score(executions : Int32, avg_ms : Float64, max_ms : Float64) : Float64
          score = 100.0
          score -= {(executions - 100) / 50.0, 30.0}.min if executions > 100
          score -= {(avg_ms - 50) / 25.0, 40.0}.min if avg_ms > 50
          score -= {(max_ms - 200) / 100.0, 20.0}.min if max_ms > 200
          score.clamp(0.0, 100.0)
        end
      end
    end
  end
end
