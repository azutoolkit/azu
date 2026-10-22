require "json"
require "../../query_store"

module Azu
  module Components
    module DevDashboard
      # "Database & Queries" tab of the dev dashboard: live query stream, waterfall,
      # N+1 alerts, transactions, pool health and a read-only SQL playground.
      #
      # The tab is a thin HTML skeleton; `SCRIPT` renders it from `payload`
      # (served as JSON by `Azu::Handler::DevDashboard`) and polls for new queries.
      module DatabaseTab
        # JSON consumed by the tab. `since` is the last query id the browser already has.
        def self.payload(store : QueryStore, since : Int64 = 0_i64, config : DatabaseConfiguration = Azu::CONFIG.database) : String
          all = store.queries(0_i64, QueryStore::MAX_QUERIES)
          alerts = QueryAnalysis.n_plus_one(all, config.n_plus_one_threshold)
          pool = store.pool
          JSON.build do |json|
            json.object do
              json.field "last_id", store.last_id
              json.field "instrumented", store.enabled?
              json.field "queries", store.queries(since, 500)
              json.field "stats" do
                json.object do
                  json.field "total", all.size
                  json.field "total_ms", all.sum(&.duration_ms).round(2)
                  json.field "slow", all.count { |query| query.duration_ms >= config.slow_query_ms }
                  json.field "errors", all.count(&.error?)
                  json.field "n_plus_one", alerts.size
                end
              end
              json.field "alerts", alerts
              json.field "transactions", store.transactions(50)
              json.field "pool", pool
              json.field "config" do
                json.object do
                  json.field "slow_ms", config.slow_query_ms
                  json.field "n_plus_one_threshold", config.n_plus_one_threshold
                  json.field "playground", playground_available?(store, config)
                  json.field "dialect", store.adapter.try(&.dialect)
                end
              end
            end
          end
        end

        def self.playground_available?(store : QueryStore, config : DatabaseConfiguration = Azu::CONFIG.database) : Bool
          config.playground? && Azu::CONFIG.env.development? && !store.adapter.nil?
        end

        # Builds the statement the playground executes for `mode` ("run", "explain", "explain_analyze").
        def self.playground_sql(sql : String, mode : String, dialect : String) : String?
          statement = sql.strip.rchop(';').strip
          return unless QueryAnalysis.read_only?(statement)
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

        private def render_database_section
          div id: "database", class: "section" do
            div class: "section-header" do
              h2 class: "section-title" do
                text "Database & Queries"
              end
              para class: "section-description" do
                text "Live SQL stream, N+1 detection, transactions, pool health and SQL playground"
              end
            end
            div id: "dbx-root", class: "dbx" do
              para class: "dbx-empty" do
                text "Waiting for query data..."
              end
            end
          end
        end

        STYLES = <<-'CSS'
        /* ===== Database & Queries tab ===== */
        .dbx { display: flex; flex-direction: column; gap: var(--space-4); }
        .dbx-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: var(--space-3); }
        .dbx-kpi { background: hsl(var(--card)); border: 1px solid hsl(var(--border)); border-radius: 0.5rem; padding: var(--space-3) var(--space-4); }
        .dbx-kpi-label { font-size: 0.75rem; color: hsl(var(--muted-foreground)); text-transform: uppercase; letter-spacing: 0.04em; }
        .dbx-kpi-value { font-size: 1.6rem; font-weight: 700; margin-top: var(--space-1); }
        .dbx-kpi-sub { font-size: 0.75rem; color: hsl(var(--muted-foreground)); }
        .dbx-kpi.warn .dbx-kpi-value { color: hsl(var(--status-warning)); }
        .dbx-kpi.crit .dbx-kpi-value { color: hsl(var(--status-critical)); }
        .dbx-banner { border: 1px solid hsl(var(--status-warning) / 0.5); background: hsl(var(--status-warning) / 0.1); border-radius: 0.5rem; padding: var(--space-3) var(--space-4); }
        .dbx-banner h3 { margin: 0 0 var(--space-2); font-size: 0.95rem; color: hsl(var(--status-warning)); }
        .dbx-alert { padding: var(--space-2) 0; border-top: 1px solid hsl(var(--border) / 0.5); font-size: 0.85rem; }
        .dbx-alert:first-of-type { border-top: 0; }
        .dbx-alert-meta { color: hsl(var(--muted-foreground)); font-size: 0.78rem; margin-top: 2px; }
        .dbx-tabs { display: flex; gap: var(--space-2); border-bottom: 1px solid hsl(var(--border)); }
        .dbx-tab { background: none; border: 0; border-bottom: 2px solid transparent; color: hsl(var(--muted-foreground)); padding: var(--space-2) var(--space-3); cursor: pointer; font: inherit; }
        .dbx-tab.active { color: hsl(var(--foreground)); border-bottom-color: hsl(var(--primary)); }
        .dbx-filters { display: flex; flex-wrap: wrap; gap: var(--space-3); align-items: center; font-size: 0.85rem; }
        .dbx-filters input[type=number], .dbx-filters select { background: hsl(var(--input)); color: hsl(var(--foreground)); border: 1px solid hsl(var(--border)); border-radius: 0.375rem; padding: 4px 8px; font: inherit; }
        .dbx-table-wrap { overflow-x: auto; border: 1px solid hsl(var(--border)); border-radius: 0.5rem; background: hsl(var(--card)); }
        .dbx-table { width: 100%; border-collapse: collapse; font-size: 0.82rem; }
        .dbx-table th { text-align: left; padding: var(--space-2) var(--space-3); color: hsl(var(--muted-foreground)); font-weight: 500; border-bottom: 1px solid hsl(var(--border)); white-space: nowrap; }
        .dbx-table td { padding: var(--space-2) var(--space-3); border-bottom: 1px solid hsl(var(--border) / 0.4); vertical-align: top; }
        .dbx-table tr.dbx-row { cursor: pointer; }
        .dbx-table tr.dbx-row:hover { background: hsl(var(--accent) / 0.5); }
        .dbx-table tr.err td { background: hsl(var(--status-critical) / 0.08); }
        .dbx-sql { font-family: 'JetBrains Mono', monospace; font-size: 0.78rem; white-space: pre-wrap; word-break: break-word; max-width: 560px; }
        .dbx-sql .kw { color: hsl(var(--crystal)); font-weight: 600; }
        .dbx-sql .str { color: hsl(var(--status-warning)); }
        .dbx-sql .num { color: hsl(var(--performance)); }
        .dbx-sql .cmt { color: hsl(var(--muted-foreground)); }
        .dbx-badge { display: inline-block; min-width: 3.4em; text-align: center; padding: 1px 8px; border-radius: 999px; font-size: 0.75rem; font-weight: 600; font-family: 'JetBrains Mono', monospace; }
        .dbx-badge.fast { background: hsl(var(--status-healthy) / 0.18); color: hsl(var(--status-healthy)); }
        .dbx-badge.medium { background: hsl(var(--status-warning) / 0.18); color: hsl(var(--status-warning)); }
        .dbx-badge.slow { background: hsl(var(--status-critical) / 0.18); color: hsl(var(--status-critical)); }
        .dbx-badge.state-open { background: hsl(var(--primary) / 0.18); color: hsl(var(--primary)); }
        .dbx-badge.state-committed { background: hsl(var(--status-healthy) / 0.18); color: hsl(var(--status-healthy)); }
        .dbx-badge.state-rolled_back { background: hsl(var(--status-critical) / 0.18); color: hsl(var(--status-critical)); }
        .dbx-chip { display: inline-block; font-size: 0.72rem; padding: 0 6px; border-radius: 4px; background: hsl(var(--secondary)); margin-right: 4px; }
        .dbx-chip.n1 { background: hsl(var(--status-warning) / 0.2); color: hsl(var(--status-warning)); }
        .dbx-muted { color: hsl(var(--muted-foreground)); }
        .dbx-detail { background: hsl(var(--muted) / 0.4); }
        .dbx-wf { display: grid; grid-template-columns: 1fr 70px; gap: 4px var(--space-3); align-items: center; margin-top: var(--space-2); }
        .dbx-wf-track { position: relative; height: 12px; background: hsl(var(--secondary)); border-radius: 3px; }
        .dbx-wf-bar { position: absolute; top: 0; bottom: 0; border-radius: 3px; min-width: 2px; background: hsl(var(--status-healthy)); }
        .dbx-wf-bar.medium { background: hsl(var(--status-warning)); }
        .dbx-wf-bar.slow { background: hsl(var(--status-critical)); }
        .dbx-wf-bar.current { outline: 2px solid hsl(var(--primary)); }
        .dbx-btn { background: hsl(var(--secondary)); color: hsl(var(--foreground)); border: 1px solid hsl(var(--border)); border-radius: 0.375rem; padding: 4px 12px; cursor: pointer; font: inherit; }
        .dbx-btn.primary { background: hsl(var(--primary)); color: hsl(var(--primary-foreground)); border-color: transparent; }
        .dbx-btn:disabled { opacity: 0.5; cursor: not-allowed; }
        .dbx-editor { width: 100%; min-height: 110px; background: hsl(var(--input)); color: hsl(var(--foreground)); border: 1px solid hsl(var(--border)); border-radius: 0.5rem; padding: var(--space-3); font-family: 'JetBrains Mono', monospace; font-size: 0.85rem; box-sizing: border-box; }
        .dbx-actions { display: flex; gap: var(--space-2); flex-wrap: wrap; align-items: center; }
        .dbx-error { color: hsl(var(--status-critical)); font-family: 'JetBrains Mono', monospace; font-size: 0.82rem; white-space: pre-wrap; }
        .dbx-empty { color: hsl(var(--muted-foreground)); padding: var(--space-4); text-align: center; }
        .dbx-toast { position: fixed; bottom: 20px; right: 20px; background: hsl(var(--foreground)); color: hsl(var(--background)); padding: 6px 12px; border-radius: 6px; font-size: 0.8rem; z-index: 1000; }
        @media (max-width: 720px) { .dbx-sql { max-width: 260px; } }
        CSS

        SCRIPT = <<-'JS'
        // ===== Database & Queries tab =====
        const dbx = (function () {
          const MAX = 2000;
          const state = { queries: [], lastId: 0, data: null, sub: 'queries', open: null,
                          filters: { minMs: 0, table: '', errorsOnly: false }, timer: null, playground: { sql: 'SELECT 1', result: null, error: null, busy: false } };
          const KEYWORDS = /^(select|from|where|and|or|not|insert|into|values|update|set|delete|join|left|right|inner|outer|on|group|by|order|having|limit|offset|as|in|is|null|like|between|exists|union|distinct|count|sum|avg|min|max|asc|desc|case|when|then|else|end|begin|commit|rollback|returning|with|explain|analyze|query|plan)$/i;
          const root = () => document.getElementById('dbx-root');
          const base = () => location.pathname.replace(/\/+$/, '');

          function el(tag, attrs, children) {
            const node = document.createElement(tag);
            for (const key in (attrs || {})) {
              const value = attrs[key];
              if (key === 'class') node.className = value;
              else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
              else if (value !== null && value !== undefined && value !== false) node.setAttribute(key, value === true ? '' : value);
            }
            [].concat(children === undefined ? [] : children).forEach(child => {
              if (child === null || child === undefined || child === false) return;
              node.appendChild(typeof child === 'object' ? child : document.createTextNode(String(child)));
            });
            return node;
          }

          function highlight(sql) {
            const out = document.createDocumentFragment();
            const re = /('(?:[^']|'')*')|(--[^\n]*)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]+)/g;
            let last = 0, m;
            while ((m = re.exec(sql)) !== null) {
              if (m.index > last) out.appendChild(document.createTextNode(sql.slice(last, m.index)));
              const cls = m[1] ? 'str' : m[2] ? 'cmt' : m[3] ? 'num' : KEYWORDS.test(m[4]) ? 'kw' : null;
              out.appendChild(cls ? el('span', { class: cls }, m[0]) : document.createTextNode(m[0]));
              last = re.lastIndex;
            }
            if (last < sql.length) out.appendChild(document.createTextNode(sql.slice(last)));
            return out;
          }

          function toast(message) {
            const node = el('div', { class: 'dbx-toast' }, message);
            document.body.appendChild(node);
            setTimeout(() => node.remove(), 1400);
          }

          function copy(text) {
            const done = () => toast('SQL copied');
            if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, done);
            else { const ta = el('textarea', {}, text); document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); done(); }
          }

          function badgeClass(ms) { return ms < 5 ? 'fast' : ms < 50 ? 'medium' : 'slow'; }
          function fmt(ms) { return ms < 1 ? ms.toFixed(2) + 'ms' : ms < 1000 ? ms.toFixed(1) + 'ms' : (ms / 1000).toFixed(2) + 's'; }
          function badge(ms) { return el('span', { class: 'dbx-badge ' + badgeClass(ms) }, fmt(ms)); }

          function visible() {
            const f = state.filters;
            return state.queries.filter(q => q.duration_ms >= f.minMs && (!f.table || q.table === f.table) && (!f.errorsOnly || q.error));
          }

          function n1Keys() {
            const keys = new Set();
            ((state.data && state.data.alerts) || []).forEach(a => keys.add((a.request_id || '') + '|' + a.normalized_sql));
            return keys;
          }

          function kpi(label, value, sub, cls) {
            return el('div', { class: 'dbx-kpi ' + (cls || '') }, [el('div', { class: 'dbx-kpi-label' }, label), el('div', { class: 'dbx-kpi-value' }, value), el('div', { class: 'dbx-kpi-sub' }, sub || '')]);
          }

          function renderKpis(d) {
            const pool = d.pool;
            const active = pool ? Math.max(pool.open - pool.idle, 0) : 0;
            const usage = pool && pool.max > 0 ? Math.round(active * 100 / pool.max) + '%' : (pool ? active + ' active' : 'n/a');
            return el('div', { class: 'dbx-kpis' }, [
              kpi('Total Queries', d.stats.total, d.stats.errors + ' errors, ' + d.stats.slow + ' slow', d.stats.errors ? 'crit' : d.stats.slow ? 'warn' : ''),
              kpi('Total DB Time', fmt(d.stats.total_ms), d.stats.total ? 'avg ' + fmt(d.stats.total_ms / d.stats.total) : ''),
              kpi('N+1 Alerts', d.stats.n_plus_one, 'threshold ' + d.config.n_plus_one_threshold + 'x per request', d.stats.n_plus_one ? 'warn' : ''),
              kpi('Pool Usage', usage, pool ? 'open ' + pool.open + ' / idle ' + pool.idle + ' / max ' + (pool.max || 'unbounded') : 'no adapter attached', pool && pool.max > 0 && active / pool.max > 0.8 ? 'crit' : '')
            ]);
          }

          function renderAlerts(d) {
            if (!d.alerts.length) return null;
            return el('div', { class: 'dbx-banner' }, [el('h3', {}, 'N+1 query warning: ' + d.alerts.length + ' repeated query shape' + (d.alerts.length > 1 ? 's' : '') + ' detected')].concat(d.alerts.map(a =>
              el('div', { class: 'dbx-alert' }, [
                el('div', {}, [el('strong', {}, a.count + 'x '), el('span', { class: 'dbx-sql' }, highlight(a.sample_sql)), ' ', badge(a.total_ms)]),
                el('div', { class: 'dbx-alert-meta' }, [(a.endpoint || '') + ' ' + (a.path || ''), a.caller ? ' | at ' + a.caller : '', a.suggestion ? ' | ' + a.suggestion : ''])
              ]))));
          }

          function waterfall(q) {
            const same = state.queries.filter(x => x.request_id && x.request_id === q.request_id);
            if (same.length < 2) return el('div', { class: 'dbx-muted' }, 'Only query in this request.');
            const start = Math.min.apply(null, same.map(x => x.started_ms));
            const end = Math.max.apply(null, same.map(x => x.started_ms + x.duration_ms));
            const span = Math.max(end - start, 1);
            const grid = el('div', { class: 'dbx-wf' });
            same.forEach(x => {
              const left = ((x.started_ms - start) / span * 100).toFixed(2);
              const width = Math.max(x.duration_ms / span * 100, 0.4).toFixed(2);
              grid.appendChild(el('div', { class: 'dbx-wf-track', title: x.sql }, el('div', { class: 'dbx-wf-bar ' + badgeClass(x.duration_ms) + (x.id === q.id ? ' current' : ''), style: 'left:' + left + '%;width:' + width + '%' })));
              grid.appendChild(el('span', { class: 'dbx-muted' }, fmt(x.duration_ms)));
            });
            return el('div', {}, [el('div', { class: 'dbx-muted' }, 'Request waterfall: ' + same.length + ' queries over ' + fmt(span)), grid]);
          }

          function detail(q) {
            return el('tr', { class: 'dbx-detail' }, el('td', { colspan: 6 }, [
              el('div', { class: 'dbx-sql' }, highlight(q.sql)),
              q.params.length ? el('div', { class: 'dbx-muted' }, 'Bindings: ' + q.params.join(', ')) : null,
              q.error ? el('div', { class: 'dbx-error' }, q.error) : null,
              el('div', { class: 'dbx-muted' }, ['Fiber ' + q.fiber_id, q.transaction_id ? ' | tx #' + q.transaction_id : '', q.caller ? ' | ' : '', q.caller ? el('code', { title: 'Call site' }, q.caller) : null]),
              waterfall(q)
            ]));
          }

          function renderQueries(d) {
            const rows = visible();
            const tables = Array.from(new Set(state.queries.map(q => q.table).filter(Boolean))).sort();
            const n1 = n1Keys();
            const filters = el('div', { class: 'dbx-filters' }, [
              el('label', {}, ['Min ms ', el('input', { type: 'number', min: 0, step: 1, value: state.filters.minMs, onchange: e => { state.filters.minMs = parseFloat(e.target.value) || 0; draw(); } })]),
              el('label', {}, ['Table ', el('select', { onchange: e => { state.filters.table = e.target.value; draw(); } }, [el('option', { value: '' }, 'all')].concat(tables.map(t => el('option', { value: t, selected: t === state.filters.table }, t))))]),
              el('label', {}, [el('input', { type: 'checkbox', checked: state.filters.errorsOnly, onchange: e => { state.filters.errorsOnly = e.target.checked; draw(); } }), ' errors only']),
              el('span', { class: 'dbx-muted' }, rows.length + ' of ' + state.queries.length + ' queries'),
              el('button', { class: 'dbx-btn', onclick: () => { fetch(base() + '?clear=true', { redirect: 'manual' }).finally(() => { state.queries = []; state.lastId = 0; poll(); }); } }, 'Clear')
            ]);
            if (!rows.length) return el('div', {}, [filters, el('div', { class: 'dbx-empty' }, d.instrumented ? 'No queries match. Hit an endpoint that talks to the database.' : 'Query instrumentation is not installed. require "azu/cql" and call Azu::CQL.schema / Azu::CQL.attach.')]);
            const body = el('tbody');
            rows.slice().reverse().slice(0, 300).forEach(q => {
              const isN1 = n1.has((q.request_id || '') + '|' + q.normalized_sql);
              body.appendChild(el('tr', { class: 'dbx-row' + (q.error ? ' err' : ''), onclick: () => { state.open = state.open === q.id ? null : q.id; draw(); } }, [
                el('td', {}, [el('span', { class: 'dbx-chip' }, q.operation), q.table || '', isN1 ? el('span', { class: 'dbx-chip n1' }, 'N+1') : null]),
                el('td', {}, el('div', { class: 'dbx-sql', title: 'Click row for details', onclick: e => { if (e.altKey || e.metaKey || e.ctrlKey) { e.stopPropagation(); copy(q.sql); } } }, highlight(q.sql.length > 400 ? q.sql.slice(0, 400) + '...' : q.sql))),
                el('td', {}, badge(q.duration_ms)),
                el('td', {}, q.rows == null ? '-' : q.rows),
                el('td', { class: 'dbx-muted' }, (q.endpoint || q.path || '-')),
                el('td', {}, el('button', { class: 'dbx-btn', title: 'Copy SQL', onclick: e => { e.stopPropagation(); copy(q.sql); } }, 'Copy'))
              ]));
              if (state.open === q.id) body.appendChild(detail(q));
            });
            return el('div', {}, [filters, el('div', { class: 'dbx-table-wrap' }, el('table', { class: 'dbx-table' }, [
              el('thead', {}, el('tr', {}, ['Method / Table', 'SQL', 'Time', 'Rows', 'Endpoint', ''].map(h => el('th', {}, h)))), body]))]);
          }

          function renderTransactions(d) {
            if (!d.transactions.length) return el('div', { class: 'dbx-empty' }, 'No transactions recorded yet.');
            const body = el('tbody');
            d.transactions.forEach(t => body.appendChild(el('tr', {}, [
              el('td', {}, '#' + t.id + (t.nested ? ' (nested)' : '')),
              el('td', {}, el('span', { class: 'dbx-badge state-' + t.state }, t.state.replace('_', ' '))),
              el('td', {}, t.query_count + ' queries'),
              el('td', {}, t.state === 'open' ? 'running' : badge(t.duration_ms)),
              el('td', { class: 'dbx-muted' }, t.endpoint || t.request_id || '-'),
              el('td', { class: 'dbx-error' }, t.error || '')
            ])));
            return el('div', { class: 'dbx-table-wrap' }, el('table', { class: 'dbx-table' }, [el('thead', {}, el('tr', {}, ['Transaction', 'State', 'Work', 'Duration', 'Request', 'Error'].map(h => el('th', {}, h)))), body]));
          }

          function runPlayground(mode) {
            const pg = state.playground;
            pg.busy = true; pg.error = null; draw();
            fetch(base() + '/sql', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'azu-dashboard' }, body: JSON.stringify({ sql: pg.sql, mode: mode }) })
              .then(r => r.json().then(j => ({ ok: r.ok, j: j })))
              .then(r => { pg.busy = false; if (r.ok) { pg.result = r.j; pg.error = null; } else { pg.result = null; pg.error = r.j.error || 'Request failed'; } draw(); poll(); })
              .catch(e => { pg.busy = false; pg.error = String(e); draw(); });
          }

          function renderPlayground(d) {
            const pg = state.playground;
            if (!d.config.playground) return el('div', { class: 'dbx-empty' }, 'The SQL playground is available only in the development environment, from localhost, once a database is attached (Azu::CQL.schema / attach).');
            const editor = el('textarea', { class: 'dbx-editor', spellcheck: 'false', oninput: e => { pg.sql = e.target.value; } }, pg.sql);
            const parts = [editor, el('div', { class: 'dbx-actions' }, [
              el('button', { class: 'dbx-btn primary', disabled: pg.busy, onclick: () => runPlayground('run') }, 'Run'),
              el('button', { class: 'dbx-btn', disabled: pg.busy, onclick: () => runPlayground('explain') }, 'Explain'),
              el('button', { class: 'dbx-btn', disabled: pg.busy, onclick: () => runPlayground('explain_analyze') }, 'Explain Analyze'),
              el('span', { class: 'dbx-muted' }, 'Read-only: single SELECT / WITH / EXPLAIN, always rolled back (' + (d.config.dialect || 'sql') + ')')
            ])];
            if (pg.error) parts.push(el('div', { class: 'dbx-error' }, pg.error));
            if (pg.result) {
              const r = pg.result;
              parts.push(el('div', { class: 'dbx-muted' }, r.rows.length + ' rows in ' + fmt(r.duration_ms) + (r.truncated ? ' (truncated)' : '')));
              parts.push(el('div', { class: 'dbx-table-wrap' }, el('table', { class: 'dbx-table' }, [
                el('thead', {}, el('tr', {}, r.columns.map(c => el('th', {}, c)))),
                el('tbody', {}, r.rows.map(row => el('tr', {}, row.map(v => el('td', { class: 'dbx-sql' }, v === null ? 'NULL' : v)))))])));
            }
            return el('div', { class: 'dbx' }, parts);
          }

          function draw() {
            const d = state.data, node = root();
            if (!d || !node) return;
            const active = document.activeElement;
            if (active && active.classList.contains('dbx-editor')) return; // never clobber the editor while typing
            const tabs = el('div', { class: 'dbx-tabs' }, [['queries', 'Queries'], ['transactions', 'Transactions (' + d.transactions.length + ')'], ['playground', 'SQL Playground']].map(t =>
              el('button', { class: 'dbx-tab' + (state.sub === t[0] ? ' active' : ''), onclick: () => { state.sub = t[0]; draw(); } }, t[1])));
            const content = state.sub === 'queries' ? renderQueries(d) : state.sub === 'transactions' ? renderTransactions(d) : renderPlayground(d);
            node.replaceChildren.apply(node, [renderKpis(d), renderAlerts(d), tabs, content].filter(Boolean));
          }

          function poll() {
            if (!root()) return Promise.resolve();
            return fetch(base() + '/queries.json?since=' + state.lastId, { headers: { 'Accept': 'application/json' } })
              .then(r => r.json())
              .then(d => {
                if (d.last_id < state.lastId) state.queries = []; // store was cleared
                state.queries = state.queries.concat(d.queries).slice(-MAX);
                state.lastId = d.last_id;
                state.data = d;
                draw();
              }).catch(() => {});
          }

          function active() { const s = document.getElementById('database'); return !!(s && s.classList.contains('active')); }
          function start() {
            poll();
            if (state.timer) return;
            state.timer = setInterval(() => { if (!document.hidden && active()) poll(); }, 2000);
          }
          return { start: start, poll: poll, active: active };
        })();
        document.addEventListener('DOMContentLoaded', () => dbx.start());
        JS
      end
    end
  end
end
