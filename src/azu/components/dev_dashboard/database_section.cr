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
              empty_state "n/a", "CQL performance monitoring is not active. Require cql before azu and enable CQL::Performance to see queries, slow statements and N+1 patterns here.", "database"
            end
            return
          end

          render_database_kpis(db)
          render_slow_queries
          render_query_patterns
          render_n_plus_one
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
