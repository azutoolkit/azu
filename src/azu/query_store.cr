require "json"

module Azu
  # Database observability data model used by the dev dashboard. It is
  # ORM-agnostic: integrations (such as `azu/cql`) record into the store.

  # One executed SQL statement, tagged with the HTTP request that caused it.
  struct QueryMetric
    include JSON::Serializable

    getter id : Int64
    getter request_id : String?
    getter endpoint : String?
    getter method : String?
    getter path : String?
    getter fiber_id : UInt64
    getter sql : String
    getter normalized_sql : String
    getter operation : String
    getter table : String?
    getter params : Array(String)
    getter duration_ms : Float64
    getter rows : Int64?
    getter error : String?
    getter caller : String?
    getter transaction_id : Int64?
    getter started_ms : Int64

    def initialize(@id, @request_id, @endpoint, @method, @path, @fiber_id, @sql, @normalized_sql,
                   @operation, @table, @params, @duration_ms, @rows, @error, @caller,
                   @transaction_id, @started_ms)
    end

    def error? : Bool
      !@error.nil?
    end

    def select? : Bool
      @operation == "SELECT"
    end
  end

  # Lifecycle of one database transaction (`state`: open, committed, rolled_back).
  class TransactionMetric
    include JSON::Serializable

    getter id : Int64
    property state : String
    getter nested : Bool
    getter request_id : String?
    getter endpoint : String?
    getter started_ms : Int64
    property duration_ms : Float64
    property query_count : Int32
    property error : String?

    def initialize(@id, @state, @nested, @request_id, @endpoint, @started_ms,
                   @duration_ms = 0.0, @query_count = 0, @error = nil)
    end
  end

  # Connection pool snapshot.
  struct PoolSnapshot
    include JSON::Serializable

    getter open : Int32
    getter idle : Int32
    getter in_flight : Int32
    getter max : Int32

    def initialize(@open, @idle, @in_flight, @max)
    end

    # Connections currently checked out.
    def active : Int32
      {@open - @idle, 0}.max
    end

    # Active connections as a percentage of the pool limit (0 when unbounded).
    def usage_percent : Float64
      @max > 0 ? (active * 100.0 / @max).round(1) : 0.0
    end
  end

  # The same query shape executed repeatedly within one request.
  struct NPlusOneAlert
    include JSON::Serializable

    getter request_id : String?
    getter endpoint : String?
    getter path : String?
    getter normalized_sql : String
    getter sample_sql : String
    getter table : String?
    getter count : Int32
    getter total_ms : Float64
    getter caller : String?
    getter suggestion : String?

    def initialize(@request_id, @endpoint, @path, @normalized_sql, @sample_sql, @table,
                   @count, @total_ms, @caller, @suggestion)
    end
  end

  # Result of a read-only playground query.
  struct SqlResult
    include JSON::Serializable

    getter columns : Array(String)
    getter rows : Array(Array(String?))
    getter duration_ms : Float64
    getter truncated : Bool

    def initialize(@columns, @rows, @duration_ms, @truncated = false)
    end
  end

  # Hooks an ORM integration provides to the dashboard.
  abstract class DatabaseAdapter
    # Runs read-only SQL (always rolled back) and returns columns and rows.
    abstract def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}

    abstract def pool : PoolSnapshot?

    # Adapter name used to pick the EXPLAIN dialect: "sqlite", "postgres", ...
    abstract def dialect : String
  end

  # Pure query-analysis helpers (no I/O, easy to test).
  module QueryAnalysis
    extend self

    def normalize(sql : String) : String
      sql
        .gsub(/'(?:[^']|'')*'/, "?")
        .gsub(/\$\d+/, "?")
        .gsub(/\b\d+(?:\.\d+)?\b/, "?")
        .gsub(/\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i, "IN (?)")
        .gsub(/\s+/, " ")
        .strip
    end

    def operation(sql : String) : String
      sql.lstrip.split(/\s+/, 2).first?.try(&.upcase) || ""
    end

    def table(sql : String) : String?
      sql.match(/\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"\[]?(\w+)/i).try(&.[1])
    end

    # Suggests an eager-load for `SELECT ... FROM children WHERE children.parent_id = ?`.
    def suggestion(normalized : String, table : String?) : String?
      return unless table && normalized.matches?(/\bWHERE\b.*\b\w*_id\b["`\]]?\s*=\s*\?/i)
      "Eager-load with preload(:#{table}) on the parent query"
    end

    # Groups repeated SELECT shapes per request. Only groups at/over `threshold` are alerts.
    def n_plus_one(queries : Array(QueryMetric), threshold : Int32) : Array(NPlusOneAlert)
      groups = Hash({String?, String}, Array(QueryMetric)).new
      queries.each do |query|
        next unless query.select? && !query.request_id.nil?
        (groups[{query.request_id, query.normalized_sql}] ||= [] of QueryMetric) << query
      end

      alerts = [] of NPlusOneAlert
      groups.each_value do |group|
        next if group.size < threshold
        first = group.first
        alerts << NPlusOneAlert.new(
          first.request_id, first.endpoint, first.path, first.normalized_sql, first.sql, first.table,
          group.size, group.sum(&.duration_ms), first.caller, suggestion(first.normalized_sql, first.table)
        )
      end
      alerts.sort_by! { |alert| -alert.count }
    end

    # Only a single SELECT / WITH / EXPLAIN statement may run in the playground.
    # Comments and multiple statements are rejected; keywords inside string
    # literals are ignored.
    def read_only?(sql : String) : Bool
      stripped = sql.strip.rchop(';').strip
      return false if stripped.empty? || stripped.includes?("--") || stripped.includes?("/*")
      code = stripped.gsub(/'(?:[^']|'')*'/, "''")
      return false if code.includes?(';')
      return false if code.matches?(/\b(?:insert|update|delete|drop|alter|create|truncate|grant|revoke|attach|detach|pragma|vacuum|copy|call|do|replace|merge|lock)\b/i)
      code.matches?(/\A(?:select|with|explain)\b/i)
    end

    # The statement the dashboard playground executes for `mode` ("run", "explain",
    # "explain_analyze"), or nil when `sql` is not allowed. EXPLAIN only wraps SELECT / WITH
    # (EXPLAIN ANALYZE would execute it); SQLite has no ANALYZE, so it explains the plan.
    def playground_sql(sql : String, mode : String, dialect : String) : String?
      statement = sql.strip.rchop(';').strip
      return unless read_only?(statement)
      case mode
      when "run" then statement
      when "explain", "explain_analyze"
        return unless statement.matches?(/\A(?:select|with)\b/i)
        case dialect
        when "sqlite"   then "EXPLAIN QUERY PLAN #{statement}"
        when "postgres" then mode == "explain_analyze" ? "EXPLAIN (ANALYZE, BUFFERS) #{statement}" : "EXPLAIN #{statement}"
        else                 "EXPLAIN #{statement}"
        end
      end
    end
  end

  # Thread-safe, bounded store of recent queries/transactions for the dashboard.
  class QueryStore
    MAX_QUERIES      = 2_000
    MAX_TRANSACTIONS =   200

    @@instance = new
    @@mutex = Mutex.new

    def self.instance : QueryStore
      @@instance
    end

    @queries = Deque(QueryMetric).new
    @transactions = Deque(TransactionMetric).new
    @open_transactions = {} of Int64 => TransactionMetric
    @next_id = 0_i64
    @pool_provider : Proc(PoolSnapshot?)? = nil
    property adapter : DatabaseAdapter? = nil
    property? enabled : Bool = false

    # The SQL playground needs a database, the development environment and the config switch
    # (the handler additionally requires a loopback client).
    def playground_available?(config : DatabaseConfiguration = Azu::CONFIG.database) : Bool
      config.playground? && Azu::CONFIG.env.development? && !@adapter.nil?
    end

    def pool_provider=(provider : Proc(PoolSnapshot?)?)
      @pool_provider = provider
    end

    def record_query(sql : String, params : Array(String), duration_ms : Float64, rows : Int64?,
                     error : String?, caller_location : String?, transaction_id : Int64?,
                     request_id : String?, endpoint : String?, method : String?, path : String?,
                     fiber_id : UInt64) : QueryMetric
      normalized = QueryAnalysis.normalize(sql)
      metric = @@mutex.synchronize do
        @next_id += 1
        entry = QueryMetric.new(
          @next_id, request_id, endpoint, method, path, fiber_id, sql, normalized,
          QueryAnalysis.operation(sql), QueryAnalysis.table(sql), params, duration_ms, rows, error,
          caller_location, transaction_id, Time.utc.to_unix_ms - duration_ms.to_i64
        )
        @queries << entry
        @queries.shift if @queries.size > MAX_QUERIES
        @open_transactions[transaction_id].try { |tx| tx.query_count += 1 } if transaction_id
        entry
      end
      warn_if_slow(metric)
      metric
    end

    # Slow-query alert: one warning per statement at or over `database.slow_query_ms` (0 disables it).
    private def warn_if_slow(metric : QueryMetric) : Nil
      threshold = Azu::CONFIG.database.slow_query_ms
      return if threshold <= 0 || metric.duration_ms < threshold
      origin = metric.endpoint.try { |name| " in #{name}" }
      sql = metric.sql.gsub(/\s+/, " ")
      sql = "#{sql[0, 300]}..." if sql.size > 300
      Azu::CONFIG.log.warn { "Slow query (#{metric.duration_ms.round(1)}ms, limit #{threshold.round(1)}ms)#{origin}: #{sql}" }
    end

    def record_transaction_begin(id : Int64, nested : Bool, request_id : String?, endpoint : String?) : Nil
      @@mutex.synchronize do
        tx = TransactionMetric.new(id, "open", nested, request_id, endpoint, Time.utc.to_unix_ms)
        @open_transactions[id] = tx
        @transactions << tx
        @transactions.shift if @transactions.size > MAX_TRANSACTIONS
      end
    end

    def record_transaction_end(id : Int64, committed : Bool, duration_ms : Float64, error : String? = nil) : Nil
      @@mutex.synchronize do
        if tx = @open_transactions.delete(id)
          tx.state = committed ? "committed" : "rolled_back"
          tx.duration_ms = duration_ms
          tx.error = error
        end
      end
    end

    # Queries newer than `since` (an id), oldest first.
    def queries(since : Int64 = 0_i64, limit : Int32 = 500) : Array(QueryMetric)
      @@mutex.synchronize do
        result = @queries.select { |query| query.id > since }
        result.size > limit ? result.last(limit) : result
      end
    end

    def transactions(limit : Int32 = 50) : Array(TransactionMetric)
      @@mutex.synchronize { @transactions.to_a.last(limit).reverse }
    end

    def last_id : Int64
      @@mutex.synchronize { @next_id }
    end

    def pool : PoolSnapshot?
      @pool_provider.try(&.call) || @adapter.try(&.pool)
    end

    def n_plus_one(threshold : Int32 = 3) : Array(NPlusOneAlert)
      QueryAnalysis.n_plus_one(queries(0_i64, MAX_QUERIES), threshold)
    end

    def clear : Nil
      @@mutex.synchronize do
        @queries.clear
        @transactions.clear
        @open_transactions.clear
      end
    end
  end
end
