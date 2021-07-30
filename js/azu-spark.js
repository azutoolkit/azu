import { h, render, hydrate } from 'https://unpkg.com/preact?module';
import htm from 'https://unpkg.com/htm?module';

const html = htm.bind(h);

var url = new URL(location.href);
url.protocol = url.protocol.replace('http', 'ws');
url.pathname = '/spark';
var live_view = new WebSocket(url);

const sparkRenderEvent = new CustomEvent('spark-render');

live_view.addEventListener('open', (event) => {
  // Hydrate client-side rendering
  document.querySelectorAll('[data-spark-view]')
    .forEach((view) => {
      var node = html(view.innerHTML)[0];
      hydrate(node, view.children[0]);

      live_view.send(JSON.stringify({
        subscribe: view.getAttribute('data-spark-view'),
      }))
    });
});

live_view.addEventListener('message', (event) => {
  var html = htm.bind(h);
  var data = event.data;
  var { id, content } = JSON.parse(data);

  document.querySelectorAll(`[data-spark-view="${id}"]`)
    .forEach((view) => {
      var div = window.$('<div>' + content + '</div>');
      view.children[0].innerHTML = div[0].innerHTML
      render(div[0], view, view.children[0]);

      document.dispatchEvent(sparkRenderEvent);
    });
});

live_view.addEventListener('close', (event) => {
  // Do we need to do anything here?
});

[
  'click',
  'change',
  'input',
].forEach((event_type) => {
  document.addEventListener(event_type, (event) => {
    var element = event.target;
    var event_name = element.getAttribute('live-' + event_type);

    if (typeof event_name === 'string') {
      var channel = event
        .target
        .closest('[data-spark-view]')
        .getAttribute('data-spark-view')

      var data = {};
      switch (element.type) {
        case "checkbox": data = { value: element.checked }; break;
        // Are there others?
        default: data = { value: element.getAttribute('live-value') || element.value }; break;
      }

      live_view.send(JSON.stringify({
        event: event_name,
        data: JSON.stringify(data),
        channel: channel,
      }));
    }
  });
});