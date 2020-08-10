(() => {
  var converter = preactHtmlConverter.PreactHTMLConverter();
  var html = converter.convert;

  var url = new URL(location.href);
  url.protocol = url.protocol.replace("http", "ws");
  url.pathname = "/live-view";
  var live_view = new WebSocket(url);
<<<<<<< HEAD
<<<<<<< HEAD
  live_view.addEventListener('open', (event) => {
    // Hydrate client-side rendering
    document.querySelectorAll('[data-live-view]')
      .forEach((view)=> {
=======
  live_view.addEventListener("open", event => {
    // Hydrate client-side rendering
    document.querySelectorAll("[data-live-view]")
      .forEach(view => {
>>>>>>> Fix js formatting
=======
  live_view.addEventListener("open", (event) => {
    // Hydrate client-side rendering
    document.querySelectorAll("[data-live-view]")
      .forEach((view)=> {
>>>>>>> Fixes JS
        var node = html(view.innerHTML)[0];
        preact.render(node, view, view.children[0]);
        live_view.send(JSON.stringify({
          subscribe: view.getAttribute("data-live-view"),
        }))
      });
  });

<<<<<<< HEAD
<<<<<<< HEAD
  live_view.addEventListener('message', (event) => {
=======
  live_view.addEventListener("message", event => {
>>>>>>> Fix js formatting
=======
  live_view.addEventListener("message", (event) => {
>>>>>>> Fixes JS
    var data = event.data;
    var { id, render } = JSON.parse(data);

    document.querySelectorAll(`[data-live-view="${id}"]`)
<<<<<<< HEAD
<<<<<<< HEAD
      .forEach((view) => {
        preact.render(html('<div>' + render + '</div>')[0], view, view.children[0]);
      });
  });

  live_view.addEventListener('close', (event) => {
=======
      .forEach(view => {
=======
      .forEach((view) => {
>>>>>>> Fixes JS
        preact.render(html("<div>" + render + "</div>")[0], view, view.children[0]);
      });
  });

<<<<<<< HEAD
  live_view.addEventListener("close", event => {
>>>>>>> Fix js formatting
=======
  live_view.addEventListener("close", (event) => {
>>>>>>> Fixes JS
    // Do we need to do anything here?
  });

  [
<<<<<<< HEAD
    'click',
    'change',
    'input',
  ].forEach((event_type) => {
    document.addEventListener(event_type, (event) => {
=======
    "click",
    "change",
    "input",
<<<<<<< HEAD
  ].forEach(event_type => {
    document.addEventListener(event_type, event => {
>>>>>>> Fix js formatting
=======
  ].forEach((event_type) => {
    document.addEventListener(event_type, (event) => {
>>>>>>> Fixes JS
      var element = event.target;
      var event_name = element.getAttribute("live-" + event_type);

      if(typeof event_name === "string") {
        var channel = event
          .target
          .closest("[data-live-view]")
          .getAttribute("data-live-view")

        var data = {};
        switch(element.type) {
          case "checkbox": data = { value: element.checked }; break;
          // Are there others?
          default: data = { value: element.getAttribute("live-value") || element.value }; break;
        }

        live_view.send(JSON.stringify({
          event: event_name,
          data: JSON.stringify(data),
          channel: channel,
        }));
      }
    });
  });
})();
