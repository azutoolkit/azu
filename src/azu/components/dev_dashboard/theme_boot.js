// Runs at the top of <body>, before first paint: applies the remembered (or system)
// theme and sidebar state to <body class="azd"> so the page never flashes.
// Storage keys are shared with dashboard.js.
(function () {
  var theme, sidebar;
  try {
    theme = localStorage.getItem('azu-dashboard-theme');
    sidebar = localStorage.getItem('azu-dashboard-sidebar');
  } catch (e) { /* storage blocked: fall back to system preference */ }
  if (theme !== 'light' && theme !== 'dark') {
    theme = matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  }
  document.body.dataset.theme = theme;
  if (sidebar === 'collapsed') document.body.dataset.collapsed = 'true';
})();
