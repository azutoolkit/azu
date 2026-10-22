/*! Azu Spark client. No dependencies; served by the application itself (see Azu::Spark::Client). */
(function () {
  "use strict";

  var PROTOCOL = 1;
  var script = document.currentScript;
  var config = {
    path: (script && script.getAttribute("data-spark-path")) || "/spark",
    backoffMin: 500,
    backoffMax: 15000,
    requestTimeout: 10000
  };

  var ws = null;
  var status = "disconnected";
  var hello = null;
  var nextId = 0;
  var attempts = 0;
  var reconnectTimer = null;
  var watchdogTimer = null;
  var heartbeatTimer = null;
  var lastFrameAt = 0;
  var stopped = false;
  var booted = false;
  var pending = new Map(); // request id -> {element, undo, sentAt}
  var joined = new Set(); // root ids joined on the current socket
  var snapshots = new Map(); // root id -> signed state snapshot
  var timers = new WeakMap(); // element -> {kind: timer or time}

  // ---- helpers --------------------------------------------------------------------------

  function emit(name, detail, target) {
    (target || document).dispatchEvent(new CustomEvent("spark:" + name, { bubbles: true, detail: detail }));
  }

  function setStatus(next) {
    if (status === next) return;
    status = next;
    document.documentElement.setAttribute("data-spark-status", next);
    emit(next, { attempts: attempts });
  }

  function byId(id) {
    return document.querySelector('[data-spark-id="' + String(id).replace(/["\\]/g, "\\$&") + '"]');
  }

  function roots(scope) {
    return Array.prototype.slice.call((scope || document).querySelectorAll("[data-spark-root]"));
  }

  function socketUrl() {
    var url = new URL(config.path, location.href);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return url.toString();
  }

  function pageParams() {
    var params = {};
    new URLSearchParams(location.search).forEach(function (value, key) { params[key] = value; });
    return params;
  }

  function transmit(message) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    var text = JSON.stringify(message);
    if (hello && text.length > hello.max_size) {
      emit("error", { code: "too_large", message: "message exceeds " + hello.max_size + " bytes" });
      return false;
    }
    ws.send(text);
    return true;
  }

  // ---- connection lifecycle ---------------------------------------------------------------

  function connect() {
    if (stopped || (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN))) return;
    clearTimeout(reconnectTimer);
    setStatus(attempts === 0 ? "connecting" : "reconnecting");
    var socket = new WebSocket(socketUrl());
    ws = socket;
    socket.onmessage = function (event) { if (ws === socket) receive(event.data); };
    socket.onclose = function (event) { if (ws === socket) lost(event); };
    socket.onerror = function () { /* onclose follows */ };
  }

  function lost(event) {
    ws = null;
    hello = null;
    joined.clear();
    clearInterval(heartbeatTimer);
    clearInterval(watchdogTimer);
    cancelPending();
    if (stopped) return setStatus("disconnected");
    setStatus("disconnected");
    scheduleReconnect(event && event.code);
  }

  // Exponential backoff with full jitter, so a restarted server is not hit by every client at once.
  function backoff(attempt) {
    var ceiling = Math.min(config.backoffMax, config.backoffMin * Math.pow(2, attempt));
    return Math.round(ceiling / 2 + Math.random() * ceiling / 2);
  }

  function scheduleReconnect() {
    if (stopped) return;
    var delay = backoff(attempts++);
    emit("backoff", { delay: delay, attempts: attempts });
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  }

  // The server proposes the heartbeat interval. Only a supported one is ever used (the smallest
  // that is not below the proposal), so a missing, non-numeric or absurd value cannot become a
  // busy timer (NaN fires at once) or one that never fires.
  var HEARTBEAT_INTERVALS = [1000, 2000, 5000, 10000, 20000, 30000, 60000];

  function heartbeatInterval(proposed) {
    var wanted = Number(proposed) || 20000;
    for (var i = 0; i < HEARTBEAT_INTERVALS.length; i++) {
      if (HEARTBEAT_INTERVALS[i] >= wanted) return HEARTBEAT_INTERVALS[i];
    }
    return HEARTBEAT_INTERVALS[HEARTBEAT_INTERVALS.length - 1];
  }

  function startHeartbeat() {
    var interval = heartbeatInterval(hello.heartbeat);
    clearInterval(heartbeatTimer);
    clearInterval(watchdogTimer);
    heartbeatTimer = setInterval(function () { transmit({ v: PROTOCOL, type: "heartbeat", id: ++nextId }); }, interval);
    // Half open connections never fire `close`: give up when the server went quiet.
    watchdogTimer = setInterval(function () {
      if (Date.now() - lastFrameAt > interval * 2.5 && ws) ws.close(4000, "heartbeat timeout");
      expirePending();
    }, Math.min(interval, 5000));
  }

  function joinRoots(scope) {
    roots(scope).forEach(function (root) {
      var id = root.getAttribute("data-spark-id");
      if (joined.has(id)) return;
      joined.add(id);
      var frame = { v: PROTOCOL, type: "join", id: ++nextId, token: root.getAttribute("data-spark-token"), params: pageParams() };
      if (snapshots.has(id)) frame.snapshot = snapshots.get(id);
      transmit(frame);
    });
  }

  // ---- incoming frames --------------------------------------------------------------------

  function receive(text) {
    var message;
    lastFrameAt = Date.now();
    try { message = JSON.parse(text); } catch (e) { return; }
    switch (message.type) {
      case "hello":
        hello = message;
        attempts = 0;
        setStatus("connected");
        startHeartbeat();
        joinRoots();
        break;
      case "diff": applyDiff(message); break;
      case "reply": settle(message.id); break;
      case "redirect": navigate(message.to, message.replace); break;
      case "heartbeat": break;
      case "error": failed(message); break;
    }
  }

  function applyDiff(message) {
    (message.patches || []).forEach(function (patch) { applyPatch(patch.id, patch.html); });
    Object.keys(message.snapshots || {}).forEach(function (id) { snapshots.set(id, message.snapshots[id]); });
    (message.events || []).forEach(function (push) {
      var element = byId(push.target);
      if (element) emit(push.name, push.payload, element);
    });
  }

  function navigate(to, replace) {
    // Only addresses on this origin. Browsers drop tabs and newlines from a URL, so "/\t/host" is
    // "//host": resolve the address the way the browser will and compare origins instead of
    // looking at its first characters.
    if (typeof to !== "string") return;
    var target;
    try { target = new URL(to, location.origin); } catch (e) { return; }
    if (target.origin !== location.origin) return;
    var path = target.pathname + target.search + target.hash;
    if (replace) location.replace(path); else location.assign(path);
  }

  function failed(message) {
    settle(message.id);
    emit("error", { code: message.code, message: message.message, id: message.id });
    if (message.code === "invalid_token" || message.code === "rejected") {
      // The page can never join (expired token, refused by mount): stop retrying until reload.
      emit("expired", { code: message.code });
      if (message.code === "invalid_token") stop();
    }
  }

  // ---- DOM patching -----------------------------------------------------------------------

  function applyPatch(id, html) {
    var element = byId(id);
    if (!element) return;
    var fragment = parsePatch(html);
    sanitize(fragment);
    // Child components that did not change are not part of this patch: keep their live elements.
    var live = new Map();
    Array.prototype.forEach.call(element.querySelectorAll("[data-spark-id]"), function (child) {
      live.set(child.getAttribute("data-spark-id"), child);
    });
    morphChildren(element, fragment, live);
    element.removeAttribute("data-spark-slot");
  }

  // Parses a patch in an inert document: no script runs and no resource loads until the
  // sanitised nodes are moved into the page. Wrapping it in <template> makes the parser
  // accept fragments that only make sense in context (table rows, list items, options).
  function parsePatch(html) {
    var doc = new DOMParser().parseFromString("<template>" + html + "</template>", "text/html");
    var template = doc.querySelector("template");
    return template ? template.content : document.createDocumentFragment();
  }

  // Defence in depth for the HTML the server sends. The server escapes what it renders, and
  // components bind events with data-spark-* attributes that this client delegates, so
  // nothing legitimate needs a script element, an inline handler or a script URL: drop them,
  // so that a hole on the server side (or a hostile frame) cannot become script execution here.
  var BLOCKED_ELEMENTS = "script,iframe,frame,frameset,object,embed,applet,base,meta,link";
  var URL_ATTRIBUTES = ["href", "src", "xlink:href", "action", "formaction", "data", "poster", "background"];

  function scriptUrl(value, name) {
    // Browsers ignore ASCII whitespace and control characters inside a scheme.
    var scheme = String(value).replace(/[\u0000-\u0020]/g, "").toLowerCase();
    if (/^(javascript|vbscript):/.test(scheme)) return true;
    return /^data:/.test(scheme) && !(name === "src" && /^data:image\/(png|gif|jpe?g|webp|avif);/.test(scheme));
  }

  function sanitize(root) {
    Array.prototype.forEach.call(root.querySelectorAll(BLOCKED_ELEMENTS), function (node) { node.remove(); });
    Array.prototype.forEach.call(root.querySelectorAll("*"), function (node) {
      Array.prototype.slice.call(node.attributes).forEach(function (attr) {
        var name = attr.name.toLowerCase();
        if (name.indexOf("on") === 0 || name === "srcdoc" ||
            (URL_ATTRIBUTES.indexOf(name) >= 0 && scriptUrl(attr.value, name))) node.removeAttribute(attr.name);
      });
    });
  }

  function keyOf(node) {
    return node.nodeType === 1 ? node.getAttribute("data-spark-id") || node.id || null : null;
  }

  function similar(a, b) {
    return a.nodeType === b.nodeType && a.nodeName === b.nodeName && keyOf(a) === keyOf(b);
  }

  function morphChildren(from, to, live) {
    var cursor = from.firstChild;
    Array.prototype.slice.call(to.childNodes).forEach(function (wanted) {
      if (wanted.nodeType === 1 && wanted.hasAttribute("data-spark-slot") && live.has(keyOf(wanted))) {
        var existing = live.get(keyOf(wanted));
        if (existing === cursor) cursor = cursor.nextSibling; else from.insertBefore(existing, cursor);
        return;
      }
      if (cursor && similar(cursor, wanted)) {
        var current = cursor;
        cursor = cursor.nextSibling;
        morphNode(current, wanted, live);
        return;
      }
      var key = keyOf(wanted);
      if (key) {
        for (var n = cursor; n; n = n.nextSibling) {
          if (n.nodeType === 1 && keyOf(n) === key) {
            from.insertBefore(n, cursor);
            return morphNode(n, wanted, live);
          }
        }
      }
      from.insertBefore(wanted, cursor);
    });
    while (cursor) {
      var next = cursor.nextSibling;
      from.removeChild(cursor);
      cursor = next;
    }
  }

  function morphNode(from, to, live) {
    if (from.nodeType !== 1) {
      if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
      return;
    }
    // Component wrappers are owned by their own patches.
    if (from.hasAttribute("data-spark-id")) return;
    morphAttributes(from, to);
    morphChildren(from, to, live);
    syncFormState(from, to);
  }

  function morphAttributes(from, to) {
    Array.prototype.slice.call(from.attributes).forEach(function (attr) {
      if (!to.hasAttribute(attr.name)) from.removeAttribute(attr.name);
    });
    Array.prototype.forEach.call(to.attributes, function (attr) {
      if (from.getAttribute(attr.name) !== attr.value) from.setAttribute(attr.name, attr.value);
    });
  }

  // The user's cursor and half typed text win over the server while the control has focus.
  function syncFormState(from, to) {
    var focused = from === document.activeElement;
    var tag = from.nodeName;
    if (tag === "INPUT") {
      if (from.type === "checkbox" || from.type === "radio") from.checked = to.hasAttribute("checked");
      else if (!focused && from.value !== (to.getAttribute("value") || "")) from.value = to.getAttribute("value") || "";
    } else if (tag === "TEXTAREA") {
      if (!focused && from.value !== to.value) from.value = to.value;
    } else if (tag === "OPTION") {
      from.selected = to.hasAttribute("selected");
    }
  }

  // ---- requests ---------------------------------------------------------------------------

  function push(element, event, payload, loading) {
    var id = ++nextId;
    var undo = loading ? loading() : null;
    var target = element.closest("[data-spark-id]");
    if (!target) return;
    var targetName = element.getAttribute("spark-target");
    if (targetName === "parent") {
      target = (target.parentElement && target.parentElement.closest("[data-spark-id]")) || target;
    } else if (targetName === "root") {
      target = target.closest("[data-spark-root]") || (function (el) {
        while (el.parentElement && el.parentElement.closest("[data-spark-id]")) el = el.parentElement.closest("[data-spark-id]");
        return el;
      })(target);
    } else if (targetName) {
      var selected = document.querySelector(targetName);
      target = (selected && selected.closest("[data-spark-id]")) || target;
    }
    var sent = transmit({ v: PROTOCOL, type: "event", id: id, target: target.getAttribute("data-spark-id"), event: event, payload: payload });
    if (!sent) {
      if (undo) undo();
      emit("offline", { event: event }, element);
      return;
    }
    pending.set(id, { undo: undo, sentAt: Date.now() });
  }

  function settle(id) {
    var entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    if (entry.undo) entry.undo();
  }

  function cancelPending() {
    pending.forEach(function (entry) { if (entry.undo) entry.undo(); });
    pending.clear();
  }

  function expirePending() {
    var now = Date.now();
    pending.forEach(function (entry, id) { if (now - entry.sentAt > config.requestTimeout) settle(id); });
  }

  function loadingStates(element) {
    var label = element.getAttribute("spark-disable-with");
    var klass = element.getAttribute("spark-optimistic-class");
    if (!label && !klass) return null;
    return function () {
      var isInput = element.nodeName === "INPUT";
      var original = isInput ? element.value : element.textContent;
      if (label) { if (isInput) element.value = label; else element.textContent = label; element.disabled = true; }
      if (klass) element.classList.add.apply(element.classList, klass.split(/\s+/).filter(Boolean));
      return function () {
        if (label) { if (isInput) element.value = original; else element.textContent = original; element.disabled = false; }
        if (klass) element.classList.remove.apply(element.classList, klass.split(/\s+/).filter(Boolean));
      };
    };
  }

  function valuesOf(element) {
    var payload = {};
    Array.prototype.forEach.call(element.attributes, function (attr) {
      if (attr.name.indexOf("spark-value-") === 0) payload[attr.name.slice(12).replace(/-/g, "_")] = attr.value;
    });
    return payload;
  }

  function controlPayload(control) {
    var payload = {};
    var value;
    if (control.type === "checkbox") value = control.checked;
    else if (control.type === "file") return payload;
    else if (control.nodeName === "SELECT" && control.multiple) {
      value = Array.prototype.filter.call(control.options, function (o) { return o.selected; }).map(function (o) { return o.value; });
    } else value = control.value;
    payload.value = value;
    if (control.name) payload[control.name] = value;
    return payload;
  }

  function formPayload(form) {
    var payload = {};
    new FormData(form).forEach(function (value, key) {
      if (typeof value !== "string") return;
      if (Object.prototype.hasOwnProperty.call(payload, key)) {
        payload[key] = [].concat(payload[key], value);
      } else payload[key] = value;
    });
    return payload;
  }

  function assign(target, source) {
    Object.keys(source).forEach(function (key) { target[key] = source[key]; });
    return target;
  }

  function throttled(element, kind, name, ms, work, mode) {
    var state = timers.get(element) || {};
    timers.set(element, state);
    var key = kind + ":" + name;
    if (mode === "debounce") {
      clearTimeout(state[key]);
      state[key] = setTimeout(work, ms);
    } else {
      var now = Date.now();
      if (state[key] && now - state[key] < ms) return;
      state[key] = now;
      work();
    }
  }

  function dispatch(kind, domEvent, element) {
    var name = element.getAttribute("spark-" + kind);
    var key = element.getAttribute("spark-key");
    if (key && domEvent.key !== key) return;
    var confirmText = element.getAttribute("spark-confirm");
    if (kind === "submit" || kind === "click" || key) domEvent.preventDefault();
    var send = function () {
      if (confirmText && !window.confirm(confirmText)) return;
      var payload = valuesOf(element);
      if (element.nodeName === "FORM") assign(payload, formPayload(element));
      else if (/^(INPUT|SELECT|TEXTAREA)$/.test(element.nodeName) && kind !== "click") assign(payload, controlPayload(element));
      push(element, name, payload, loadingStates(element));
    };
    var debounce = parseInt(element.getAttribute("spark-debounce"), 10);
    var throttle = parseInt(element.getAttribute("spark-throttle"), 10);
    if (debounce > 0) throttled(element, kind, name, debounce, send, "debounce");
    else if (throttle > 0) throttled(element, kind, name, throttle, send, "throttle");
    else send();
  }

  function listen(domEvent, kind, capture, accepts) {
    document.addEventListener(domEvent, function (event) {
      var start = event.target;
      if (!(start instanceof Element)) return;
      var element = start.closest("[spark-" + kind + "]");
      if (!element || !element.closest("[data-spark-id]")) return;
      if (accepts && !accepts(event, element)) return;
      dispatch(kind, event, element);
    }, capture);
  }

  function textual(control) {
    return control.nodeName === "TEXTAREA" || (control.nodeName === "INPUT" && !/^(checkbox|radio|file|range|color|button|submit)$/.test(control.type));
  }

  function bind() {
    listen("click", "click", false);
    listen("submit", "submit", false);
    listen("keydown", "keydown", false);
    listen("keyup", "keyup", false);
    listen("blur", "blur", true);
    listen("focus", "focus", true);
    // Text controls report every keystroke (`input`); everything else reports on `change`.
    listen("input", "change", false, function (event) { return textual(event.target); });
    listen("change", "change", false, function (event) { return !textual(event.target); });
  }

  // ---- page changes -----------------------------------------------------------------------

  function observe() {
    new MutationObserver(function (records) {
      records.forEach(function (record) {
        Array.prototype.forEach.call(record.addedNodes, function (node) {
          if (node.nodeType === 1 && (node.hasAttribute("data-spark-root") || node.querySelector("[data-spark-root]"))) joinRoots(node.parentNode || document);
        });
        Array.prototype.forEach.call(record.removedNodes, function (node) {
          if (node.nodeType !== 1) return;
          var removed = node.hasAttribute("data-spark-root") ? [node] : roots(node);
          removed.forEach(function (root) {
            var id = root.getAttribute("data-spark-id");
            if (!joined.delete(id)) return;
            snapshots.delete(id);
            transmit({ v: PROTOCOL, type: "leave", target: id });
          });
        });
      });
    }).observe(document.body, { childList: true, subtree: true });
  }

  function stop() {
    stopped = true;
    clearTimeout(reconnectTimer);
    if (ws) ws.close(1000, "stopped");
  }

  function start() {
    if (booted) return;
    booted = true;
    bind();
    observe();
    window.addEventListener("online", function () { attempts = 0; connect(); });
    window.addEventListener("pageshow", function (event) { if (event.persisted) { stopped = false; attempts = 0; connect(); } });
    window.addEventListener("pagehide", function () { stopped = true; if (ws) ws.close(1000, "page closed"); });
    if (roots().length > 0) connect();
    else document.addEventListener("DOMContentLoaded", function () { if (roots().length > 0) connect(); });
  }

  window.AzuSpark = {
    get status() { return status; },
    connect: function () { stopped = false; connect(); },
    disconnect: stop,
    push: function (element, event, payload) { push(element, event, payload || {}); }
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
