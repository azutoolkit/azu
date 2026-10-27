require "./registry"

module Azu
  class ExceptionPage
    # The "Database" signals: the queries the failing request ran, from `QueryStore` (filled by `azu/cql` when
    # database instrumentation is on). It names the failing statement, repeated statements (N+1) and the slowest one.
    module DatabasePanel
      extend self

      ROWS          = 25
      MANY_QUERIES  = 20
      N_PLUS_ONE_AT =  3

      def build(report : Report, store : QueryStore = QueryStore.instance) : Array(Panel)
        return [] of Panel unless store.enabled? && (request_id = report.request.id)

        queries = store.queries(0_i64, QueryStore::MAX_QUERIES).select { |query| query.request_id == request_id }
        return [] of Panel if queries.empty?

        failed = queries.select(&.error?)
        repeated = QueryAnalysis.n_plus_one(queries, N_PLUS_ONE_AT)
        slowest = queries.max_by(&.duration_ms)
        total_ms = queries.sum(&.duration_ms)

        stats = [
          Stat.new("Queries", queries.size.to_s, queries.size > MANY_QUERIES ? Tone::Warn : Tone::Info),
          Stat.new("Time in SQL", "#{total_ms.round(1)} ms"),
          Stat.new("Failed", failed.size.to_s, failed.empty? ? Tone::Good : Tone::Bad),
          Stat.new("N+1 patterns", repeated.size.to_s, repeated.empty? ? Tone::Good : Tone::Warn),
        ]
        rows = queries.last(ROWS).map do |query|
          [query.operation, query.table || "", "#{query.duration_ms.round(2)} ms", query.normalized_sql, query.error || ""]
        end
        note = queries.size > ROWS ? "The last #{ROWS} of #{queries.size} queries." : nil

        [Panel.new("Database", "database", stats, ["Operation", "Table", "Time", "SQL", "Error"], rows,
          hints(failed, repeated, slowest), note)]
      end

      private def hints(failed : Array(QueryMetric), repeated : Array(NPlusOneAlert), slowest : QueryMetric) : Array(Hint)
        hints = [] of Hint
        failed.first?.try do |query|
          hints << Hint.new("A SQL statement failed: #{query.error}",
            "#{query.normalized_sql}#{query.caller.try { |site| " (from #{site})" }}", Tone::Bad)
        end
        repeated.first?.try do |alert|
          hints << Hint.new("N+1: the same query ran #{alert.count} times in this request",
            "#{alert.normalized_sql}#{alert.caller.try { |site| " (from #{site})" }}. #{alert.suggestion || "Load the rows in one query."}",
            Tone::Warn)
        end
        threshold = Azu.current_config.database.slow_query_ms
        if threshold > 0 && slowest.duration_ms >= threshold
          hints << Hint.new("A slow query took #{slowest.duration_ms.round(1)} ms",
            "#{slowest.normalized_sql} is over `database.slow_query_ms` (#{threshold.round(1)} ms): a timeout may follow from it.",
            Tone::Warn)
        end
        hints
      end
    end

    on_panels { |report| DatabasePanel.build(report) }
  end
end
