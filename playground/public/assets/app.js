// Azu Playground progressive enhancement. Every page and form works without this file;
// it adds the theme toggle, dismissible toasts, native <dialog> confirmations, busy buttons,
// the live WebSocket panel and the slow-report loader.
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $all(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function store(op, key, value) {
    try { return op === "get" ? localStorage.getItem(key) : op === "set" ? localStorage.setItem(key, value) : localStorage.removeItem(key); } catch (e) { return null; }
  }

  /* ---- Theme toggle: system -> light -> dark ---- */
  var toggle = $("[data-theme-toggle]");
  if (toggle) {
    var root = document.documentElement;
    var order = ["system", "light", "dark"];
    var current = function () { return root.getAttribute("data-theme") || "system"; };
    var paint = function () {
      var mode = current();
      toggle.setAttribute("data-mode", mode);
      var label = $("[data-theme-label]", toggle);
      var visible = mode === "system" ? "Auto" : mode === "light" ? "Light" : "Dark";
      if (label) label.textContent = visible;
      // The accessible name starts with the visible text (WCAG 2.5.3, label in name).
      toggle.setAttribute("aria-label", visible + " colour theme. Activate to change.");
    };
    toggle.hidden = false;
    toggle.addEventListener("click", function () {
      var next = order[(order.indexOf(current()) + 1) % order.length];
      if (next === "system") { root.removeAttribute("data-theme"); store("remove", "azu-theme"); }
      else { root.setAttribute("data-theme", next); store("set", "azu-theme", next); }
      paint();
    });
    paint();
  }

  /* ---- Toasts: flash messages become auto-dismissing toasts ---- */
  function dismiss(el) {
    if (reduceMotion) { el.remove(); return; }
    el.classList.add("is-leaving");
    setTimeout(function () { el.remove(); }, 220);
  }
  $all("[data-toast]").forEach(function (el) {
    var close = el.querySelector("[data-toast-close]");
    if (close) { close.hidden = false; close.addEventListener("click", function () { dismiss(el); }); }
    var timer = setTimeout(function () { dismiss(el); }, 7000);
    el.addEventListener("focusin", function () { clearTimeout(timer); });
    el.addEventListener("mouseenter", function () { clearTimeout(timer); });
  });

  /* ---- Busy state for submit buttons (prevents double submits) ---- */
  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (event.defaultPrevented || !(form instanceof HTMLFormElement)) return;
    $all("button[type=submit]", form).forEach(function (btn) {
      setTimeout(function () { btn.classList.add("is-busy"); btn.setAttribute("aria-disabled", "true"); }, 0);
    });
  });
  window.addEventListener("pageshow", function (event) {
    if (event.persisted) $all(".is-busy").forEach(function (b) { b.classList.remove("is-busy"); b.removeAttribute("aria-disabled"); });
  });

  /* ---- Confirm dialogs: <form data-confirm="..."> ---- */
  var dialog = $("#confirm-dialog");
  if (dialog && typeof dialog.showModal === "function") {
    var pending = null;
    document.addEventListener("submit", function (event) {
      var form = event.target;
      if (!(form instanceof HTMLFormElement) || !form.hasAttribute("data-confirm") || form.__confirmed) return;
      event.preventDefault();
      pending = form;
      $("[data-dialog-title]", dialog).textContent = form.getAttribute("data-confirm-title") || "Are you sure?";
      $("[data-dialog-body]", dialog).textContent = form.getAttribute("data-confirm");
      $("[data-dialog-ok]", dialog).textContent = form.getAttribute("data-confirm-label") || "Confirm";
      dialog.showModal();
    }, true);
    $("[data-dialog-ok]", dialog).addEventListener("click", function () {
      var form = pending; pending = null;
      dialog.close("ok");
      if (form) { form.__confirmed = true; form.requestSubmit(); }
    });
    $("[data-dialog-cancel]", dialog).addEventListener("click", function () { pending = null; dialog.close("cancel"); });
    dialog.addEventListener("click", function (event) {
      // The dialog element is also its own padding, so a click on it only means "outside" when it
      // lands beyond the box (the backdrop), not inside the padding around the content.
      var box = dialog.getBoundingClientRect();
      var outside = event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom;
      if (event.target === dialog && outside) { pending = null; dialog.close("cancel"); }
    });
    // Undo the busy state set by the capture-phase listener ordering above.
    dialog.addEventListener("close", function () {
      $all(".is-busy").forEach(function (b) { if (!b.form || !b.form.__confirmed) { b.classList.remove("is-busy"); b.removeAttribute("aria-disabled"); } });
    });
  }

  /* ---- Move focus to the first invalid field after a failed submit ---- */
  var firstInvalid = $("[aria-invalid=true]");
  var summary = $("[data-form-summary]");
  if (summary) summary.focus(); else if (firstInvalid) firstInvalid.focus();

  /* ---- Realtime panel (/realtime) ---- */
  var live = $("[data-realtime]");
  if (live) {
    var statusBadge = $("[data-rt-status]", live);
    var statusText = $("[data-rt-status-text]", live);
    var countEl = $("[data-rt-count]", live);
    var logEl = $("[data-rt-log]", live);
    var emptyEl = $("[data-rt-empty]", live);
    var sendBtn = $("[data-rt-send]", live);
    var socket = null, retry = 0;

    var setState = function (state, text) {
      statusBadge.classList.remove("is-good", "is-warn", "is-bad");
      statusBadge.classList.add(state === "open" ? "is-good" : state === "connecting" ? "is-warn" : "is-bad");
      statusText.textContent = text;
      sendBtn.disabled = state !== "open";
    };
    var addLog = function (text) {
      if (emptyEl) emptyEl.hidden = true;
      var li = document.createElement("li");
      var time = document.createElement("time");
      time.textContent = new Date().toLocaleTimeString([], { hour12: false });
      var span = document.createElement("span");
      span.textContent = text;
      li.appendChild(time); li.appendChild(span);
      logEl.insertBefore(li, logEl.firstChild);
      while (logEl.children.length > 50) logEl.removeChild(logEl.lastChild);
    };
    var connect = function () {
      setState("connecting", "Connecting");
      var proto = location.protocol === "https:" ? "wss://" : "ws://";
      socket = new WebSocket(proto + location.host + live.getAttribute("data-realtime"));
      socket.addEventListener("open", function () { retry = 0; setState("open", "Connected"); addLog("Connected to the channel."); });
      socket.addEventListener("message", function (event) {
        var msg;
        try { msg = JSON.parse(event.data); } catch (e) { addLog(String(event.data)); return; }
        if (typeof msg.subscribers === "number") countEl.textContent = String(msg.subscribers);
        if (msg.type === "polo") addLog("Polo! The channel answered everyone connected.");
        else if (msg.type === "presence") addLog(msg.subscribers === 1 ? "You are the only one here." : msg.subscribers + " people are connected.");
      });
      socket.addEventListener("close", function () {
        setState("closed", "Disconnected");
        var delay = Math.min(10000, 800 * Math.pow(2, retry++));
        addLog("Connection lost. Retrying in " + Math.round(delay / 1000) + "s.");
        setTimeout(connect, delay);
      });
    };
    sendBtn.addEventListener("click", function () {
      if (socket && socket.readyState === WebSocket.OPEN) { socket.send("Marco!"); addLog("You said Marco!"); }
    });
    connect();
  }

  /* ---- Slow report loader (/cache): shows a skeleton while the 5s request runs ---- */
  var loader = $("[data-slow-report]");
  if (loader) {
    var out = $("[data-slow-output]", loader);
    var skeleton = $("[data-slow-skeleton]", loader);
    var button = $("[data-slow-run]", loader);
    var link = $("[data-slow-fallback]", loader);
    if (link) link.hidden = true;
    button.hidden = false;
    button.addEventListener("click", function () {
      button.disabled = true; skeleton.hidden = false; out.hidden = true;
      var started = performance.now();
      fetch(loader.getAttribute("data-slow-report"), { headers: { Accept: "application/json" } })
        .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
        .then(function (data) {
          var ms = Math.round(performance.now() - started);
          out.textContent = JSON.stringify(data, null, 2);
          out.hidden = false;
          var note = $("[data-slow-note]", loader);
          note.textContent = (data.cached ? "Served from the cache" : "Generated fresh") + " in " + (ms / 1000).toFixed(1) + " s. Run it again to see the cache hit.";
        })
        .catch(function (err) { out.textContent = "Could not load the report (" + err.message + ")."; out.hidden = false; })
        .then(function () { skeleton.hidden = true; button.disabled = false; });
    });
  }
})();
