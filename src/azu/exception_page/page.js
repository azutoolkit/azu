/*
 * Azu exception page behaviour: tabs (ARIA, arrow keys, `#hash`), the theme toggle shared with the dev dashboard
 * (same storage key, so a choice made in one holds in the other) and copy buttons. Vanilla JS, no dependencies;
 * without it every panel is shown (see the page's <noscript> style).
 */
(() => {
  'use strict';

  const root = document.body;
  const $ = (selector) => root.querySelector(selector);
  const $$ = (selector) => [...root.querySelectorAll(selector)];

  // ---------- tabs ----------
  const tabs = () => $$('[role="tab"]');

  function selectTab(id, { focus = false, hash = true } = {}) {
    const tab = document.getElementById(`tab-${id}`);
    if (!tab) return;
    tabs().forEach((t) => {
      t.setAttribute('aria-selected', String(t === tab));
      t.tabIndex = t === tab ? 0 : -1;
    });
    $$('.azd-panel').forEach((panel) => panel.classList.toggle('is-active', panel.id === `panel-${id}`));
    if (focus) tab.focus();
    if (hash) { try { history.replaceState(null, '', `#${id}`); } catch { /* sandboxed frame */ } }
  }

  function tabKey(event) {
    const list = tabs();
    const index = list.indexOf(event.target);
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
    let next;
    if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = list.length - 1;
    else if (step) next = (index + step + list.length) % list.length;
    else return false;
    selectTab(list[next].dataset.tab, { focus: true });
    return true;
  }

  // ---------- theme ----------
  function setTheme(theme, remember) {
    root.dataset.theme = theme;
    if (remember) { try { localStorage.setItem('azu-dashboard-theme', theme); } catch { /* storage blocked */ } }
    $('[data-action="theme"]').setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`);
  }

  // ---------- clipboard ----------
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

  async function copyFrom(button) {
    const what = (button.getAttribute('aria-label') || '').replace(/^Copy /, '');
    toast((await copyText(button.dataset.copy || '')) ? `Copied ${what}` : 'Copy failed: select the text manually');
  }

  // ---------- wiring ----------
  const actions = {
    tab: (el) => selectTab(el.dataset.tab, { focus: true }),
    theme: () => setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark', true),
    copy: copyFrom,
  };

  document.addEventListener('click', (event) => {
    const trigger = event.target.closest('[data-action]');
    if (!trigger) return;
    event.preventDefault();
    actions[trigger.dataset.action]?.(trigger);
  });

  document.addEventListener('keydown', (event) => {
    if (event.target.matches?.('[role="tab"]') && tabKey(event)) event.preventDefault();
  });

  addEventListener('hashchange', () => selectTab(location.hash.slice(1), { hash: false }));

  setTheme(root.dataset.theme === 'light' ? 'light' : 'dark', false);
  if (document.getElementById(`tab-${location.hash.slice(1)}`)) selectTab(location.hash.slice(1), { hash: false });
})();
