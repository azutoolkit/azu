// Azu Spark client: connects live components to the server over a WebSocket.
//
// No dependencies. Include it with `Azu::Spark.javascript_tag` (or the `spark_tag()`
// template helper), or serve this file as <script type="module" src="/azu-spark.js">.
//
// Attributes understood in component markup (`spark_click: :save` renders `spark-click="save"`):
//
//   spark-click | spark-change | spark-input | spark-keydown   event name to send
//   spark-submit                                              on <form>: sends all fields
//   spark-value="x"        value to send for buttons and links
//   spark-key="Enter"      only react to this key (with spark-keydown)
//   spark-debounce="300"   milliseconds to wait after the last input event
//   spark-target="<id>"    deliver to another component instead of the enclosing one
//   spark-reset            on <form spark-submit>: reset the form after sending
//   spark-ignore           never touch the children of this element when re-rendering
//
// The legacy live-click / live-change / live-input / live-value attributes still work.

const SPARK_PATH =
  document.querySelector('script[data-spark-path]')?.dataset.sparkPath ||
  window.AZU_SPARK_PATH ||
  '/spark';

const subscribed = new Set();
const outbox = [];
const debouncers = new WeakMap();
let socket = null;
let attempts = 0;

function viewId(element) {
  return element.closest('[data-spark-view]')?.getAttribute('data-spark-view') || null;
}

function send(payload) {
  const message = JSON.stringify(payload);
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(message);
  } else {
    outbox.push(message);
  }
}

function subscribe(view) {
  const id = view.getAttribute('data-spark-view');
  if (!id || subscribed.has(id)) return;
  subscribed.add(id);
  send({ subscribe: id });
}

function subscribeAll() {
  document.querySelectorAll('[data-spark-view]').forEach(subscribe);
}

function connect() {
  const url = new URL(location.href);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.pathname = SPARK_PATH;
  url.search = '';
  url.hash = '';

  socket = new WebSocket(url);

  socket.addEventListener('open', () => {
    attempts = 0;
    subscribed.clear();
    // Events clicked while offline are dropped: replaying stale actions would surprise users.
    outbox.length = 0;
    subscribeAll();
    document.dispatchEvent(new CustomEvent('spark-connect'));
  });

  socket.addEventListener('message', (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (_) {
      return;
    }
    render(message.id, message.content);
  });

  socket.addEventListener('close', () => {
    document.dispatchEvent(new CustomEvent('spark-disconnect'));
    if (attempts < 8) {
      setTimeout(connect, Math.min(1000 * 2 ** attempts, 15000));
      attempts += 1;
    }
  });
}

// ---------------------------------------------------------------------------
// Re-rendering: morph the DOM instead of replacing it, so focus, caret position and
// text the user is typing survive an update.
// ---------------------------------------------------------------------------

function render(id, content) {
  document.querySelectorAll(`[data-spark-view="${CSS.escape(id)}"]`).forEach((view) => {
    const target = view.firstElementChild || view.appendChild(document.createElement('div'));
    const next = document.createElement('div');
    next.innerHTML = content;
    morphChildren(target, next);
    document.dispatchEvent(new CustomEvent('spark-render', { detail: { id } }));
  });
}

function keyOf(node) {
  return node.nodeType === Node.ELEMENT_NODE
    ? node.getAttribute('data-key') || node.id || null
    : null;
}

function sameKind(a, b) {
  return a.nodeType === b.nodeType && a.nodeName === b.nodeName;
}

function morphChildren(from, to) {
  const existing = Array.from(from.childNodes);
  const used = new Set();
  const keyed = new Map();
  existing.forEach((node) => {
    const key = keyOf(node);
    if (key) keyed.set(key, node);
  });

  let position = 0;
  Array.from(to.childNodes).forEach((target) => {
    const key = keyOf(target);
    let match = null;

    if (key) {
      match = keyed.get(key) || null;
    } else {
      for (let i = position; i < existing.length; i += 1) {
        const candidate = existing[i];
        if (!used.has(candidate) && !keyOf(candidate) && sameKind(candidate, target)) {
          match = candidate;
          break;
        }
      }
    }

    if (match && sameKind(match, target)) {
      used.add(match);
      morphNode(match, target);
    } else {
      match = document.importNode(target, true);
    }

    const current = from.childNodes[position];
    if (current !== match) from.insertBefore(match, current || null);
    position += 1;
  });

  while (from.childNodes.length > position) from.removeChild(from.lastChild);
}

function morphNode(from, to) {
  if (from.nodeType !== Node.ELEMENT_NODE) {
    if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
    return;
  }

  Array.from(from.attributes).forEach((attribute) => {
    if (!to.hasAttribute(attribute.name)) from.removeAttribute(attribute.name);
  });
  Array.from(to.attributes).forEach((attribute) => {
    if (from.getAttribute(attribute.name) !== attribute.value) {
      from.setAttribute(attribute.name, attribute.value);
    }
  });

  syncFormControl(from, to);
  if (!from.hasAttribute('spark-ignore') && from.nodeName !== 'TEXTAREA') {
    morphChildren(from, to);
  }
}

function syncFormControl(from, to) {
  // Never overwrite what the user is typing in the focused control.
  if (from === document.activeElement) return;

  switch (from.nodeName) {
    case 'INPUT':
      if (from.type === 'checkbox' || from.type === 'radio') {
        from.checked = to.hasAttribute('checked');
      } else if (from.type !== 'file') {
        from.value = to.getAttribute('value') ?? '';
      }
      break;
    case 'TEXTAREA':
      from.value = to.textContent;
      break;
    case 'SELECT':
      Array.from(from.options).forEach((option, index) => {
        option.selected = to.options[index]?.hasAttribute('selected') || false;
      });
      break;
    default:
  }
}

// ---------------------------------------------------------------------------
// Sending events
// ---------------------------------------------------------------------------

function valueOf(element) {
  if (element.hasAttribute('spark-value')) return element.getAttribute('spark-value');
  if (element.hasAttribute('live-value')) return element.getAttribute('live-value');
  if (element.type === 'checkbox') return element.checked;
  if (element.type === 'radio') return element.checked ? element.value : null;
  if (element.multiple && element.options) {
    return Array.from(element.selectedOptions).map((option) => option.value);
  }
  return element.value ?? '';
}

function formFields(form) {
  const fields = {};
  new FormData(form).forEach((value, name) => {
    if (typeof value !== 'string') return; // files are not sent over the socket
    if (name in fields) {
      fields[name] = [].concat(fields[name], value);
    } else {
      fields[name] = value;
    }
  });
  return fields;
}

function emit(element, name, data) {
  const channel = element.getAttribute('spark-target') || viewId(element);
  if (!channel || !name) return;
  send({ event: name, data: JSON.stringify(data), channel });
}

function dispatch(element, name, type) {
  const payload = { value: valueOf(element) };
  if (element.name) payload.name = element.name;

  const delay = parseInt(element.getAttribute('spark-debounce') || '0', 10);
  if (delay > 0 && type === 'input') {
    clearTimeout(debouncers.get(element));
    debouncers.set(element, setTimeout(() => emit(element, name, payload), delay));
  } else {
    emit(element, name, payload);
  }
}

[
  ['click', 'spark-click', 'live-click'],
  ['change', 'spark-change', 'live-change'],
  ['input', 'spark-input', 'live-input'],
  ['keydown', 'spark-keydown', null],
].forEach(([type, attribute, legacy]) => {
  document.addEventListener(type, (event) => {
    if (!event.target.closest) return;
    const selector = legacy ? `[${attribute}], [${legacy}]` : `[${attribute}]`;
    const element = event.target.closest(selector);
    if (!element) return;

    if (type === 'keydown') {
      const wanted = element.getAttribute('spark-key');
      if (wanted && event.key !== wanted) return;
    }
    if (type === 'click' && element.tagName === 'A') event.preventDefault();

    const name = element.getAttribute(attribute) || (legacy && element.getAttribute(legacy));
    dispatch(element, name, type);
  });
});

document.addEventListener('submit', (event) => {
  const form = event.target.closest && event.target.closest('[spark-submit], [live-submit]');
  if (!form) return;
  event.preventDefault();
  emit(form, form.getAttribute('spark-submit') || form.getAttribute('live-submit'), formFields(form));
  if (form.hasAttribute('spark-reset')) form.reset();
});

// Components added to the page later (e.g. by another component) subscribe themselves.
new MutationObserver(subscribeAll).observe(document.documentElement, {
  childList: true,
  subtree: true,
});

window.AzuSpark = { send, connect, subscribeAll };

connect();
