module Azu
  module Database
    # PostgreSQL health report behind `azu db:analyze`: sizes, unused/duplicate/invalid indexes,
    # dead-tuple pressure, tables read by sequential scan, cache hit ratio, connections and
    # long-running statements. Read-only (statistics views only).
    #
    # ```
    # puts Azu::Database::Maintenance.new.to_text
    # Azu::Database::Maintenance.new.analyze! # refreshes planner statistics (ANALYZE)
    # ```
    class Maintenance
      record Section, title : String, columns : Array(String), rows : Array(Array(String?)), advice : String

      QUERIES = [
        {"Largest tables", 15, "Sizes include indexes and TOAST. A table dominating the database is where tuning pays off.", <<-SQL},
          SELECT relname AS "table", n_live_tup AS "live rows", n_dead_tup AS "dead rows",
                 pg_size_pretty(pg_total_relation_size(relid)) AS "total size"
          FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC
        SQL
        {"Unused indexes", 20, "Never scanned since statistics were reset, and not enforcing uniqueness. Candidates to drop (confirm on a long-lived replica first).", <<-SQL},
          SELECT s.relname AS "table", s.indexrelname AS "index", pg_size_pretty(pg_relation_size(s.indexrelid)) AS "size"
          FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
          WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
          ORDER BY pg_relation_size(s.indexrelid) DESC
        SQL
        {"Duplicate indexes", 20, "Indexes with identical definitions: keep one.", <<-SQL},
          SELECT indrelid::regclass::text AS "table", string_agg(indexrelid::regclass::text, ', ') AS "indexes"
          FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          GROUP BY indrelid, indkey, indclass, indisunique, coalesce(indpred::text, ''), coalesce(indexprs::text, '')
          HAVING count(*) > 1
        SQL
        {"Invalid indexes", 20, "Left behind by a failed CREATE INDEX CONCURRENTLY. Drop and rebuild them.", <<-SQL},
          SELECT indexrelid::regclass::text AS "index", indrelid::regclass::text AS "table" FROM pg_index WHERE NOT indisvalid
        SQL
        {"Tables with many dead rows", 20, "Dead rows over 10% of the table: autovacuum is behind or the table is heavily updated. Dead-tuple ratio is an indicator of bloat, not a measurement (use pgstattuple for exact numbers).", <<-SQL},
          SELECT relname AS "table", n_live_tup AS "live rows", n_dead_tup AS "dead rows",
                 round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS "dead %",
                 coalesce(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never') AS "last autovacuum"
          FROM pg_stat_user_tables
          WHERE n_dead_tup > 1000 AND n_dead_tup > 0.1 * (n_live_tup + n_dead_tup)
          ORDER BY n_dead_tup DESC
        SQL
        {"Tables read mostly by sequential scan", 15, "Large tables with many sequential scans and few index scans: a missing index is likely.", <<-SQL},
          SELECT relname AS "table", n_live_tup AS "live rows", seq_scan AS "seq scans", coalesce(idx_scan, 0) AS "index scans"
          FROM pg_stat_user_tables
          WHERE n_live_tup > 10000 AND seq_scan > 100 AND seq_scan > coalesce(idx_scan, 0)
          ORDER BY seq_scan DESC
        SQL
        {"Long-running statements", 10, "Active for more than 5 seconds.", <<-SQL},
          SELECT pid, state, to_char(now() - query_start, 'HH24:MI:SS') AS "running", left(regexp_replace(query, '\\s+', ' ', 'g'), 100) AS "query"
          FROM pg_stat_activity
          WHERE datname = current_database() AND state <> 'idle' AND pid <> pg_backend_pid() AND now() - query_start > interval '5 seconds'
          ORDER BY query_start
        SQL
      ]

      getter schema : ::CQL::Schema

      def initialize(@schema : ::CQL::Schema = Azu::Database.schema)
      end

      def sections : Array(Section)
        result = QUERIES.map do |title, limit, advice, sql|
          columns, rows = @schema.raw_readonly(sql, limit)
          Section.new(title, columns, rows, advice)
        end
        result + [cache_and_connections]
      end

      # Refreshes the planner's statistics for every table (cheap, safe to run any time).
      def analyze! : Nil
        @schema.exec("ANALYZE")
      end

      # Cache hit ratio, connection usage and the application pool in one section.
      def cache_and_connections : Section
        _, hit = @schema.raw_readonly(<<-SQL, 1)
          SELECT round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2)::text FROM pg_statio_user_tables
        SQL
        _, conn = @schema.raw_readonly(<<-SQL, 1)
          SELECT count(*)::text, (count(*) FILTER (WHERE state = 'active'))::text, current_setting('max_connections')
          FROM pg_stat_activity WHERE datname = current_database()
        SQL
        pool = Azu::Database.connected? ? Azu::Database.pool : nil
        rows = [] of Array(String?)
        rows << ["Buffer cache hit ratio", hit.first?.try(&.first?).try { |value| "#{value}%" } || "n/a (no reads yet)"] of String?
        rows << ["Connections (active / total / max)", conn.first?.try { |row| "#{row[1]} / #{row[0]} / #{row[2]}" }] of String?
        rows << ["Application pool (in use / open / limit)", pool ? "#{pool.active} / #{pool.open} / #{pool.max > 0 ? pool.max : "unbounded"}" : "not connected"] of String?
        Section.new("Cache and connections", ["metric", "value"], rows, "A cache hit ratio under ~99% on an OLTP workload suggests too little shared_buffers or missing indexes.")
      end

      def to_text : String
        String.build do |io|
          sections.each do |section|
            io << "== " << section.title << " ==\n"
            if section.rows.empty?
              io << "  none\n\n"
              next
            end
            widths = section.columns.map_with_index { |column, i| ([column.size] + section.rows.map { |row| row[i].to_s.size }).max }
            io << "  " << section.columns.map_with_index { |column, i| column.ljust(widths[i]) }.join("  ") << '\n'
            section.rows.each { |row| io << "  " << row.map_with_index { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ") << '\n' }
            io << "  -> " << section.advice << "\n\n"
          end
        end
      end
    end
  end
end
