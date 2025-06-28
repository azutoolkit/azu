require "uuid"

module Azu
  class Spark < Channel
    COMPONENTS  = {} of String => Component
    GC_INTERVAL = 10.seconds

    gc_sweep

    def self.javascript_tag
      <<-JS
      <script type="module">
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
      </script>
      JS
    end

    private def self.gc_sweep
      spawn do
        loop do
          sleep GC_INTERVAL
          COMPONENTS.reject! do |_, component|
            component.disconnected? && (
              component.mounted? || component.age > GC_INTERVAL
            )
          end
        end
      end
    end

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code : HTTP::WebSocket::CloseCode? = nil, message : String? = nil)
      COMPONENTS.each do |id, component|
        component.unmount
        COMPONENTS.delete id
      rescue KeyError
      end
    end

    def on_message(message)
      json = JSON.parse(message)

      if channel = json["subscribe"]?
        spark = channel.to_s
        COMPONENTS[spark].connected = true
        COMPONENTS[spark].socket = socket
        COMPONENTS[spark].mount
      elsif event_name = json["event"]?
        spark = json["channel"].not_nil!
        data = json["data"].not_nil!.as_s
        COMPONENTS[spark].on_event(event_name.as_s, data)
      end
    rescue IO::Error
    rescue ex
      ex.inspect STDERR
    end
  end
end
