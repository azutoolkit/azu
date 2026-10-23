require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Database" tab: CQL query statistics. Without an active CQL monitor the
      # whole tab collapses into one explanatory "n/a" card.
      module DatabaseSection
        private abstract def provider : DashboardDataProvider

        private def render_database : Nil
          db = provider.database_stats
          unless db.active
            card "Database monitoring", "database" do
              empty_state "n/a", "CQL performance monitoring is not active. Require \"azu/cql\" and call Azu::CQL.configure to collect every query through CQL::Telemetry and see queries, slow statements and N+1 patterns here.", "database"
            end
            return
          end

          render_database_kpis(db)
          render_n_plus_one
          render_recent_queries
          render_slow_queries
          render_query_patterns
          render_database_transactions
          render_database_pool
          render_sql_playground
        end

        # Green under 5 ms, yellow under 50 ms, red beyond: the thresholds for a single statement.
        private def query_status(ms : Float64) : Status
          Status.ceiling(ms, 5.0, 50.0)
        end

        # Statements an ORM integration (`azu/cql`) recorded, each tagged with the request that ran it.
        private def render_recent_queries : Nil
          return unless provider.store_backed?
          queries = provider.recent_queries
          card "Recent queries", "logs", meta: "newest first, with the request that ran them" do
            if queries.empty?
              empty_state "No queries recorded yet", "Hit an endpoint that talks to the database.", "database"
            else
              data_table "Recent queries", ["Time", "SQL", "Rows", "Request", "Call site"] do
                queries.each { |query| render_recent_query(query) }
              end
            end
          end
        end

        private def render_recent_query(query : QueryMetric) : Nil
          tr data_filter: query.sql do
            td do
              badge query_status(query.duration_ms), Format.ms(query.duration_ms)
              badge Status::Bad, "Error" if query.error?
            end
            td class: "azd-mono azd-wrap" do
              text query.sql
              copy_button "SQL", query.sql
              paragraph query.error.to_s, class: "azd-muted" if query.error?
            end
            td query.rows.try(&.to_s) || "-"
            td class: "azd-wrap" do
              text [query.method, query.path].compact.join(" ").presence || "-"
              paragraph query.endpoint.to_s, class: "azd-muted" if query.endpoint
            end
            td query.caller || "-", class: "azd-mono azd-wrap"
          end
        end

        private def render_database_transactions : Nil
          return unless provider.store_backed?
          transactions = provider.database_transactions
          card "Transactions", "tracing", meta: "open, committed or rolled back" do
            if transactions.empty?
              empty_state "No transactions yet", "Wrap writes in Azu::CQL.transaction (or schema.transaction) to see them here.", "database"
            else
              data_table "Transactions", ["Transaction", "State", "Queries", "Duration", "Request"] do
                transactions.each do |transaction|
                  tr data_filter: nil do
                    td "##{transaction.id}#{" (nested)" if transaction.nested}"
                    td { badge transaction_status(transaction.state), transaction.state.tr("_", " ") }
                    td transaction.query_count.to_s
                    td transaction.state == "open" ? "running" : Format.ms(transaction.duration_ms)
                    td transaction.endpoint || transaction.request_id || "-"
                  end
                end
              end
            end
          end
        end

        private def transaction_status(state : String) : Status
          case state
          when "committed"   then Status::Good
          when "rolled_back" then Status::Bad
          else                    Status::Idle
          end
        end

        private def render_database_pool : Nil
          return unless provider.store_backed?
          card "Connection pool", "database" do
            if pool = provider.database_pool
              usage = pool.usage_percent
              meter usage, Status.ceiling(usage, 60.0, 85.0), "Connections in use"
              facts do
                fact "In use", pool.active.to_s
                fact "Open", pool.open.to_s
                fact "Idle", pool.idle.to_s
                fact "Limit", pool.max > 0 ? pool.max.to_s : "unbounded"
              end
            else
              empty_state "No pool information", "Define the schema with Azu::CQL.schema, or attach it with Azu::CQL.attach, to see pool usage.", "database"
            end
          end
        end

        # Read-only SELECT / EXPLAIN against the app database; `dashboard.js` posts to `<dashboard>/sql`.
        private def render_sql_playground : Nil
          return unless provider.store_backed? && provider.sql_playground?
          card "SQL playground", "database", meta: "read-only, rolled back, development only" do
            div class: "azd-sql" do
              label "SQL statement", for: "azd-sql", class: "azd-sr"
              textarea id: "azd-sql", class: "azd-sql-editor azd-mono", rows: "5", spellcheck: "false", autocomplete: "off" do
                text "SELECT 1"
              end
              div class: "azd-sql-actions" do
                button "Run", type: "button", class: "azd-btn", data_action: "sql-run", data_mode: "run"
                button "Explain", type: "button", class: "azd-btn", data_action: "sql-run", data_mode: "explain"
                button "Explain analyze", type: "button", class: "azd-btn", data_action: "sql-run", data_mode: "explain_analyze"
              end
              div id: "azd-sql-result", class: "azd-sql-result", aria_live: "polite"
            end
          end
        end

        private def render_database_kpis(db : DatabaseData::DatabaseStats) : Nil
          div class: "azd-grid azd-kpis" do
            kpi "Queries", "database" do
              kpi_value Format.number(db.queries), caption: "#{db.patterns} unique patterns, avg #{Format.ms(db.avg_ms)}"
            end
            slow = zero_is_good(db.slow, Status::Warn)
            kpi "Slow queries", "clock", slow, slow.good? ? "Clear" : "Slow" do
              kpi_value db.slow.to_s, caption: "#{db.very_slow} over 500 ms"
            end
            n_plus_one = zero_is_good(db.n_plus_one, Status::Bad)
            kpi "N+1 patterns", "alert", n_plus_one, n_plus_one.good? ? "Clear" : "Detected" do
              kpi_value db.n_plus_one.to_s, caption: "#{db.critical} critical, #{db.high} high"
            end
            health = Status.floor(db.health.to_f, 90.0, 70.0)
            wording = health.pick("Healthy", "Fair", "Poor")
            kpi("Health", "tracing", health, wording) do
              kpi_value db.health.to_s, "/100", caption: "Slowest query #{Format.ms(db.max_ms)}"
            end
          end
        end

        private def render_slow_queries : Nil
          queries = provider.slow_queries
          card "Slow queries", "clock", meta: "slowest first" do
            if queries.empty?
              empty_state "No slow queries", "Every recorded statement finished under the slow-query threshold.", "database"
            else
              ul class: "azd-queries" do
                queries.each { |query| render_slow_query(query) }
              end
            end
          end
        end

        private def render_slow_query(query : DatabaseData::SlowQuery) : Nil
          li data_filter: query.sql do
            div class: "azd-query-meta" do
              badge Status.latency(query.ms), Format.ms(query.ms)
              span "#{query.rows} rows", class: "azd-muted"
              time Format.clock(query.at), datetime: query.at.to_rfc3339, class: "azd-muted"
            end
            code_block query.sql, "SQL"
          end
        end

        private def render_query_patterns : Nil
          patterns = provider.query_patterns
          card "Query patterns", "logs", meta: "most executed first" do
            if patterns.empty?
              empty_state "No query patterns recorded", "Patterns appear as queries run.", "logs"
            else
              data_table "Query patterns", ["Pattern", "Executions", "Average", "Score"] do
                patterns.each do |pattern|
                  tr data_filter: nil do
                    td class: "azd-mono azd-wrap" do
                      text pattern.sql
                    end
                    td Format.number(pattern.executions)
                    td Format.ms(pattern.avg_ms)
                    td { badge Status.floor(pattern.score, 80.0, 60.0), pattern.score.round(0).to_i.to_s }
                  end
                end
              end
            end
          end
        end

        private def render_n_plus_one : Nil
          issues = provider.n_plus_one_issues
          card "N+1 analysis", "alert" do
            if issues.empty?
              empty_state "No N+1 patterns detected", "Repeated per-row queries would be listed here.", "check"
            else
              ul class: "azd-insights" do
                issues.each { |issue| render_n_plus_one_issue(issue) }
              end
            end
          end
        end

        private def render_n_plus_one_issue(issue : DatabaseData::NPlusOneIssue) : Nil
          li class: "azd-insight", data_filter: nil do
            badge n_plus_one_status(issue.severity), issue.severity.capitalize
            span issue.message
            copy_button "N+1 issue", issue.message
          end
        end

        private def n_plus_one_status(severity : String) : Status
          case severity
          when "critical" then Status::Bad
          when "high"     then Status::Warn
          else                 Status::Idle
          end
        end
      end
    end
  end
end
