import morphdom from 'https://cdn.jsdelivr.net/npm/morphdom@2.6.1/dist/morphdom-esm.js?module';
      
var url = new URL(location.href);
url.protocol = url.protocol.replace('http', 'ws');
url.pathname = '/sparks';
var live_view = new WebSocket(url);

const sparkRenderEvent = new CustomEvent('spark-render');

live_view.addEventListener('open', (event) => {
  document.querySelectorAll('[data-live-view]')
    .forEach((view)=> {
      live_view.send(JSON.stringify({
        subscribe: view.getAttribute('data-live-view'),
      }))
    });
});

live_view.addEventListener('message', (event) => {
  var data = event.data;
  var { id, content } = JSON.parse(data);

    document.querySelectorAll(`[data-live-view="${id}"]`).forEach((view)=>{
      var fromEl = view.querySelector('div')
      morphdom(fromEl, `<div>${content}</div>`, {
        childrenOnly: true, 
        onBeforeElUpdated: function(fromEl, toEl) {
          if (fromEl.isEqualNode(toEl)) { return false }
          return true
        }
      })
      document.dispatchEvent(sparkRenderEvent);
    })
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

    if(typeof event_name === 'string') {
      var channel = event
        .target
        .closest('[data-live-view]')
        .getAttribute('data-live-view')

      var data = {};
      switch(element.type) {
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