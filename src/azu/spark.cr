require "uuid"

module Azu
  class Spark < Channel
    def self.javascript_tags
      <<-HTML
        <script type="module">
          import { h, Component, render, hydrate} from 'https://unpkg.com/preact?module';
          import htm from 'https://unpkg.com/htm?module';
          const html = htm.bind(h);

          var url = new URL(location.href);
          url.protocol = url.protocol.replace('http', 'ws');
          url.pathname = '/live-view';
          var live_view = new WebSocket(url);

          const sparkRenderEvent = new CustomEvent('spark-render');

          live_view.addEventListener('open', (event) => {
            // Hydrate client-side rendering
            document.querySelectorAll('[data-live-view]')
              .forEach((view)=> {
                var node = html(view.innerHTML)[0];
                hydrate(node, view.children[0]);

                live_view.send(JSON.stringify({
                  subscribe: view.getAttribute('data-live-view'),
                }))
              });
          });

          live_view.addEventListener('message', (event) => {
            var html = htm.bind(h);
            var data = event.data;
            var { id, content } = JSON.parse(data);
            document.querySelectorAll(`[data-live-view="${id}"]`)
              .forEach((view) => {
                var div = window.$('<div>' + content + '</div>');
                view.children[0].innerHTML = div[0].innerHTML
                render(div[0], view, view.children[0]) ;
            
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
        </script>   
      HTML
    end

    COMPONENTS = {} of String => SparkView

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code, message)
      COMPONENTS.each do |id, component|
        component.unmount
        COMPONENTS.delete id
      end
    end

    def on_message(message : String)
      json = JSON.parse(message)

      if channel = json["subscribe"]?
        spark = channel.to_s
        COMPONENTS[spark].connected = true
        COMPONENTS[spark].socket = socket
        COMPONENTS[spark].mount
      elsif event_name = json["event"]?
        spark = json["channel"].not_nil!
        data = json["data"].not_nil!
        COMPONENTS[spark].on_event(event_name.not_nil!, data)
      end
    rescue ex : IO::Error
      puts "Socket closed"
    end
  end

  class SparkView
    property? connected = false
    getter spark_id : String = UUID.random.to_s
    @socket = uninitialized HTTP::WebSocket

    def initialize
      Spark::COMPONENTS[spark_id] = self
    end

    # Start: Live View API
    def mount
    end

    def unmount
    end

    def on_event(name, data)
    end

    def component
    end

    def refresh
      json = {content: component.to_s, id: spark_id}.to_json
      @socket.not_nil!.send json
    end

    def refresh
      yield
      refresh component
    end

    def every(duration : Time::Span, &block)
      spawn do
        while connected?
          sleep duration
          block.call if connected?
        end
      end
    end

    def socket=(other)
      @socket = other
    end

    def to_s
      String.build do |str|
        str << %{<div data-live-view="#{spark_id}"><div>}
        str << component
        str << %{</div></div>}
      end
    end
  end
end
