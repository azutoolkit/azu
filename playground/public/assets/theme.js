// Applies the stored colour scheme before first paint (loaded synchronously in <head>).
// With no stored choice, prefers-color-scheme decides in CSS. Everything is wrapped in
// try/catch because storage can throw in private windows or with blocked site data.
(function () {
  var root = document.documentElement;
  root.classList.add("js");
  try {
    var theme = localStorage.getItem("azu-theme");
    if (theme === "light" || theme === "dark") root.setAttribute("data-theme", theme);
  } catch (e) { /* storage unavailable: follow the system scheme */ }
})();
