/*
 * Azu development dashboard behaviour. Vanilla JS, no dependencies, no build step.
 *
 * Layout of this file:
 *   state    one object holding everything the UI can change
 *   helpers  DOM shortcuts and guarded localStorage
 *   views    small functions that apply `state` to the DOM (tabs, filters, theme, ...)
 *   palette  the Ctrl/Cmd+K command palette (a native modal <dialog>, so focus is trapped)
 *   refresh  soft auto-refresh that swaps the server-rendered `[data-live]` regions
 *   wiring   one delegated click handler (data-action), one keydown and one input handler
 *
 * All server data is read from the DOM and written back with textContent / DOM
 * APIs, never innerHTML, so request data shown in the page cannot execute.
 */
(() => {
  'use strict';

  const root = document.body;
  const $ = (selector, scope = root) => scope.querySelector(selector);
  const $$ = (selector, scope = root) => [...scope.querySelectorAll(selector)];
  const store = {
    get(key) { try { return localStorage.getItem(`azu-dashboard-${key}`); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(`azu-dashboard-${key}`, value); } catch { /* storage blocked */ } },
  };

  const REFRESH_MS = 15000;
  const state = {
    tab: 'overview',
    query: '',
    methods: new Set(), // HTTP verbs the route list is limited to (empty = all)
    levelsOff: new Set(['debug']), // log levels currently hidden
    auto: store.get('auto') !== 'off',
    updatedAt: Date.now(),
    sql: { text: 'SELECT 1', result: null, error: null, busy: false }, // Database tab playground
  };

  const filterInput = $('#azd-filter');
  const toggleSet = (set, value) => (set.has(value) ? set.delete(value) : set.add(value));
  const isTyping = (el) => el.matches?.('input, textarea, select, [contenteditable]');

  // ---------- tabs ----------
  const tabs = () => $$('[role="tab"]');

  function selectTab(id, { focus = false, hash = true } = {}) {
    const tab = document.getElementById(`tab-${id}`);
    if (!tab) return;
    state.tab = id;
    tabs().forEach((t) => {
      t.setAttribute('aria-selected', String(t === tab));
      t.tabIndex = t === tab ? 0 : -1;
    });
    $$('.azd-panel').forEach((panel) => panel.classList.toggle('is-active', panel.id === `panel-${id}`));
    if (focus) tab.focus();
    if (hash) { try { history.replaceState(null, '', `#${id}`); } catch { /* sandboxed frame */ } }
    announceFilter();
  }

  // Arrow keys move between tabs (roving tabindex, automatic activation).
  function tabKey(event) {
    const list = tabs();
    const index = list.indexOf(event.target);
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
    let next;
    if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = list.length - 1;
    else if (step) next = (index + step + list.length) % list.length;
    else return false;
    selectTab(list[next].dataset.tab, { focus: true });
    return true;
  }

  // ---------- filters: quick filter, verb toggles, log levels ----------
  const haystacks = new WeakMap();
  const haystack = (el) => {
    if (!haystacks.has(el)) haystacks.set(el, (el.dataset.filter || el.textContent).toLowerCase());
    return haystacks.get(el);
  };

  function applyFilters() {
    const query = state.query.trim().toLowerCase();
    $$('[data-filter]').forEach((el) => {
      const verb = el.dataset.method;
      const verbOk = !verb || !state.methods.size || state.methods.has(verb);
      el.hidden = !(verbOk && haystack(el).includes(query));
    });
    $$('[data-group]').forEach((group) => { group.hidden = !$('[data-filter]:not([hidden])', group); });
    announceFilter();
  }

  // Screen-reader summary of the active panel while a filter is in effect.
  function announceFilter() {
    const live = $('#azd-announce');
    if (!state.query.trim() && !state.methods.size) { live.textContent = ''; return; }
    const rows = $$('[data-filter]', $('.azd-panel.is-active'));
    live.textContent = `${rows.filter((row) => !row.hidden).length} of ${rows.length} results`;
  }

  function clearFilters() {
    state.query = '';
    filterInput.value = '';
    state.methods.clear();
    syncToggles();
    applyFilters();
  }

  function syncToggles() {
    $$('.azd-stream').forEach((stream) => { stream.dataset.off = [...state.levelsOff].join(' '); });
    $$('[data-action="level"]').forEach((b) => b.setAttribute('aria-pressed', String(!state.levelsOff.has(b.dataset.level))));
    $$('[data-action="method"]').forEach((b) => b.setAttribute('aria-pressed', String(state.methods.has(b.dataset.method))));
  }

  // ---------- theme and sidebar ----------
  const prefersLight = matchMedia('(prefers-color-scheme: light)');

  function setTheme(theme, remember) {
    root.dataset.theme = theme;
    if (remember) store.set('theme', theme);
    $('[data-action="theme"]').setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`);
  }
  const toggleTheme = () => setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark', true);

  function setCollapsed(collapsed) {
    root.dataset.collapsed = String(collapsed);
    const button = $('[data-action="sidebar"]');
    button.setAttribute('aria-pressed', String(collapsed));
    button.setAttribute('aria-label', collapsed ? 'Expand sidebar' : 'Collapse sidebar');
    store.set('sidebar', collapsed ? 'collapsed' : 'open');
  }

  // ---------- clipboard and toast ----------
  let toastTimer;
  function toast(message) {
    const el = $('#azd-toast');
    el.textContent = message;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.textContent = ''; }, 1800);
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch { /* insecure context or permission denied: use the textarea fallback */ }
    const previous = document.activeElement;
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
    root.append(area);
    area.select();
    let copied = false;
    try { copied = document.execCommand('copy'); } catch { /* ignore */ }
    area.remove();
    previous?.focus();
    return copied;
  }

  // Copy source: an explicit data-copy, else the nearest code block, else the row's search text.
  async function copyFrom(button) {
    const text = button.dataset.copy
      || button.closest('.azd-code')?.querySelector('pre')?.textContent
      || button.closest('[data-filter]')?.dataset.filter
      || '';
    const what = (button.getAttribute('aria-label') || '').replace(/^Copy /, '');
    toast((await copyText(text)) ? `Copied ${what}` : 'Copy failed: select the text manually');
  }

  // ---------- command palette ----------
  const palette = { dialog: $('#azd-palette'), input: $('#azd-palette-input'), list: $('#azd-palette-list'), sources: [], items: [], active: 0 };

  function showRoute(row) {
    selectTab('routes');
    clearFilters();
    row.closest('details').open = true;
    row.tabIndex = -1;
    row.scrollIntoView({ block: 'center' });
    row.focus();
  }

  function showLog(entry) {
    selectTab('logs');
    clearFilters();
    state.levelsOff.delete(entry.dataset.level);
    syncToggles();
    entry.open = true;
    entry.scrollIntoView({ block: 'center' });
    $('summary', entry).focus();
  }

  // Palette entries: what is shown (`label`), what is searched (`search`, lower-cased once) and what runs.
  // Log entries are searched by their full text (request id, endpoint, ...), not just the visible summary.
  function paletteSources() {
    const item = (kind, label, run, search = label) => ({ kind, label, run, search: search.toLowerCase() });
    const go = tabs().map((tab) => item('Tab', `Go to ${$('.azd-tab-label', tab).textContent}`, () => selectTab(tab.dataset.tab, { focus: true })));
    const actions = [
      item('Action', 'Toggle light / dark theme', toggleTheme),
      item('Action', 'Refresh data now', () => refresh(true)),
      item('Action', 'Toggle live auto-refresh', toggleAuto),
      item('Action', 'Collapse / expand sidebar', () => setCollapsed(root.dataset.collapsed !== 'true')),
      item('Action', 'Clear recorded metrics', clearMetrics),
    ];
    const routes = $$('[data-route]').map((row) => item('Route', `${row.dataset.method} ${row.dataset.route}`, () => showRoute(row)));
    const logs = $$('[data-palette="log"]').map((entry) => item(
      'Log', $$('summary > *', entry).map((part) => part.textContent).join(' '), () => showLog(entry), entry.dataset.filter,
    ));
    return [...go, ...actions, ...routes, ...logs];
  }

  function renderPalette() {
    const terms = palette.input.value.toLowerCase().split(/\s+/).filter(Boolean);
    const pool = terms.length ? palette.sources : palette.sources.filter((item) => item.kind === 'Tab' || item.kind === 'Action');
    palette.items = pool.filter((item) => terms.every((term) => item.search.includes(term))).slice(0, 50);
    palette.active = 0;
    const rows = palette.items.map((item, i) => {
      const row = document.createElement('li');
      row.id = `azd-option-${i}`;
      row.dataset.index = i;
      row.setAttribute('role', 'option');
      const label = document.createElement('span');
      label.textContent = item.label;
      const kind = document.createElement('span');
      kind.className = 'azd-palette-kind';
      kind.textContent = item.kind;
      row.append(label, kind);
      return row;
    });
    if (!rows.length) {
      const none = document.createElement('li');
      none.className = 'azd-palette-empty';
      none.setAttribute('role', 'presentation');
      none.textContent = 'No matches';
      rows.push(none);
    }
    palette.list.replaceChildren(...rows);
    markActive();
  }

  function markActive() {
    $$('[role="option"]', palette.list).forEach((row, i) => {
      row.setAttribute('aria-selected', String(i === palette.active));
      if (i === palette.active) row.scrollIntoView({ block: 'nearest' });
    });
    palette.input.setAttribute('aria-activedescendant', palette.items.length ? `azd-option-${palette.active}` : '');
  }

  function openPalette() {
    if (palette.dialog.open) return;
    palette.sources = paletteSources();
    palette.input.value = '';
    renderPalette();
    palette.dialog.showModal();
    palette.input.focus();
  }

  function runPaletteItem(index) {
    const item = palette.items[index];
    if (!item) return;
    palette.dialog.close();
    item.run();
  }

  function paletteKey(event) {
    const count = palette.items.length;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      palette.active = (palette.active + (event.key === 'ArrowDown' ? 1 : -1) + count) % Math.max(count, 1);
      markActive();
    } else if (event.key === 'Enter') {
      event.preventDefault();
      runPaletteItem(palette.active);
    }
  }

  // ---------- live refresh ----------
  function toggleAuto() {
    state.auto = !state.auto;
    store.set('auto', state.auto ? 'on' : 'off');
    $('[data-action="auto"]').setAttribute('aria-pressed', String(state.auto));
    renderStatus();
  }

  function renderStatus() {
    const age = Math.floor((Date.now() - state.updatedAt) / 1000);
    $('#azd-updated').textContent = state.auto ? 'Live' : 'Paused';
    $('#azd-age').textContent = state.auto ? `${age}s` : '';
  }

  // Automatic refreshes wait while the user is mid-task: palette open, an inspector drawer open,
  // focus inside the panels (it would be lost on swap) or text selected for copying.
  const userBusy = () => document.hidden || palette.dialog.open || $('.azd-log[open]')
    || $('#azd-panels').contains(document.activeElement) || String(getSelection()).length > 0;

  // Re-fetch the page and swap only the [data-live] regions, so the open tab, filters and toggles survive.
  async function refresh(force = false) {
    if (!force && userBusy()) return;
    try {
      const response = await fetch(location.pathname + location.search, { cache: 'no-store', credentials: 'same-origin' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const next = new DOMParser().parseFromString(await response.text(), 'text/html');
      $$('[data-live]').forEach((el) => {
        const fresh = next.getElementById(el.id);
        if (fresh) el.replaceWith(document.importNode(fresh, true));
      });
      selectTab(state.tab, { hash: false });
      syncToggles();
      applyFilters();
      renderSql();
      state.updatedAt = Date.now();
    } catch {
      $('#azd-updated').textContent = 'Offline';
      $('#azd-age').textContent = '';
    }
  }

  // ---------- SQL playground (Database tab) ----------
  const sqlNode = (tag, text, className) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    node.textContent = text;
    return node;
  };

  // Rebuilds the editor and result from `state.sql`, so a soft refresh never loses them.
  function renderSql() {
    const area = $('#azd-sql');
    const out = $('#azd-sql-result');
    if (!area || !out) return;
    if (area !== document.activeElement) area.value = state.sql.text;
    $$('[data-action="sql-run"]').forEach((button) => { button.disabled = state.sql.busy; });
    out.replaceChildren();
    if (state.sql.error) out.append(sqlNode('p', state.sql.error, 'azd-sql-error'));
    const result = state.sql.result;
    if (!result) return;

    out.append(sqlNode('p', `${result.rows.length} row(s) in ${result.duration_ms.toFixed(2)} ms${result.truncated ? ' (truncated)' : ''}`, 'azd-muted'));
    const table = sqlNode('table', '', 'azd-table');
    const head = table.createTHead().insertRow();
    result.columns.forEach((column) => { const th = sqlNode('th', column); th.scope = 'col'; head.append(th); });
    const body = table.createTBody();
    result.rows.forEach((row) => {
      const tr = body.insertRow();
      row.forEach((value) => tr.append(sqlNode('td', value === null ? 'NULL' : value, 'azd-mono azd-wrap')));
    });
    const scroll = sqlNode('div', '', 'azd-scroll');
    scroll.append(table);
    out.append(scroll);
  }

  async function runSql(mode) {
    const area = $('#azd-sql');
    if (!area) return;
    state.sql = { text: area.value, result: null, error: null, busy: true };
    renderSql();
    try {
      const response = await fetch(`${location.pathname}/sql`, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'azu-dashboard' },
        body: JSON.stringify({ sql: state.sql.text, mode }),
      });
      const body = await response.json();
      state.sql = response.ok
        ? { ...state.sql, busy: false, result: body }
        : { ...state.sql, busy: false, error: body.error || `HTTP ${response.status}` };
    } catch (error) {
      state.sql = { ...state.sql, busy: false, error: String(error) };
    }
    renderSql();
  }

  async function clearMetrics() {
    if (!confirm('Clear all recorded metrics? This resets request, cache and component history.')) return;
    await fetch(`${location.pathname}?clear=true`, { redirect: 'manual' });
    await refresh(true);
    toast('Metrics cleared');
  }

  // ---------- wiring ----------
  const actions = {
    tab: (el) => selectTab(el.dataset.tab, { focus: el.matches('[role="tab"]') }),
    palette: openPalette,
    theme: toggleTheme,
    sidebar: () => setCollapsed(root.dataset.collapsed !== 'true'),
    auto: toggleAuto,
    refresh: () => refresh(true),
    clear: clearMetrics,
    'sql-run': (el) => runSql(el.dataset.mode),
    copy: copyFrom,
    level: (el) => { toggleSet(state.levelsOff, el.dataset.level); syncToggles(); },
    method: (el) => { toggleSet(state.methods, el.dataset.method); syncToggles(); applyFilters(); },
  };

  document.addEventListener('click', (event) => {
    if (event.target === palette.dialog) { palette.dialog.close(); return; }
    const option = event.target.closest('#azd-palette-list [data-index]');
    if (option) { runPaletteItem(Number(option.dataset.index)); return; }
    const trigger = event.target.closest('[data-action]');
    if (trigger) {
      event.preventDefault();
      actions[trigger.dataset.action]?.(trigger);
    }
  });

  document.addEventListener('keydown', (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      palette.dialog.open ? palette.dialog.close() : openPalette();
    } else if (event.target === palette.input) {
      paletteKey(event);
    } else if (event.target.matches?.('[role="tab"]') && tabKey(event)) {
      event.preventDefault();
    } else if (event.key === '/' && !isTyping(event.target) && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      filterInput.focus();
    } else if (event.key === 'Escape' && event.target === filterInput) {
      if (filterInput.value) clearFilters(); else filterInput.blur();
    }
  });

  document.addEventListener('input', (event) => {
    if (event.target === filterInput) {
      state.query = filterInput.value;
      applyFilters();
    } else if (event.target === palette.input) {
      renderPalette();
    } else if (event.target.id === 'azd-sql') {
      state.sql.text = event.target.value;
    }
  });

  prefersLight.addEventListener('change', () => { if (!store.get('theme')) setTheme(prefersLight.matches ? 'light' : 'dark', false); });
  addEventListener('hashchange', () => selectTab(location.hash.slice(1), { hash: false }));

  // The tab list is vertical beside the content and horizontal on narrow screens / small iframes.
  const narrow = matchMedia('(max-width: 860px)');
  const syncOrientation = () => $('[role="tablist"]').setAttribute('aria-orientation', narrow.matches ? 'horizontal' : 'vertical');
  narrow.addEventListener('change', syncOrientation);

  // ---------- init ----------
  const apple = /Mac|iPhone|iPad/.test(navigator.userAgentData?.platform || navigator.platform);
  $$('.azd-mod').forEach((el) => { el.textContent = apple ? '⌘K' : 'Ctrl K'; });
  setTheme(root.dataset.theme === 'light' ? 'light' : 'dark', false);
  setCollapsed(root.dataset.collapsed === 'true');
  $('[data-action="auto"]').setAttribute('aria-pressed', String(state.auto));
  syncOrientation();
  syncToggles();
  selectTab(document.getElementById(`tab-${location.hash.slice(1)}`) ? location.hash.slice(1) : 'overview', { hash: false });
  renderStatus();
  renderSql();
  setInterval(renderStatus, 1000);
  setInterval(() => { if (state.auto) refresh(); }, REFRESH_MS);
})();
