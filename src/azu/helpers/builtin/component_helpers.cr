module Azu
  module Helpers
    module Builtin
      # Component helpers for integrating Spark live components in templates.
      #
      # ## Example
      #
      # ```jinja
      # <head>
      #   {{ spark_tag() }}
      # </head>
      # <body>
      #   {{ render_component("counter", initial_count=0) }}
      #
      #   <button {{ "increment" | live_click }}>+</button>
      #   <input type="text" {{ "search" | live_input }} />
      # </body>
      # ```
      module ComponentHelpers
        def self.register : Nil
          register_spark_tag
          register_live_click
          register_live_change
          register_live_input
          register_live_value
          register_component_id
        end

        private def self.register_spark_tag : Nil
          func = Crinja.function({
            path:   "/spark",
            jquery: true,
          }, :spark_tag) do
            path = arguments["path"].to_s
            include_jquery = arguments["jquery"].truthy?

            html = String.build do |io|
              # Include jQuery if requested (needed for Spark)
              if include_jquery
                io << %Q(<script src="https://code.jquery.com/jquery-3.7.1.min.js" integrity="sha256-/JqT3SQfawRcv/BIHPThkBvs0OEvtFFmqPF/lYI/Cxo=" crossorigin="anonymous"></script>\n)
              end

              # Spark JavaScript
              io << <<-JS
              <script type="module">
              import { h, render, hydrate } from 'https://unpkg.com/preact?module';
              import htm from 'https://unpkg.com/htm?module';

              const html = htm.bind(h);

              var url = new URL(location.href);
              url.protocol = url.protocol.replace('http', 'ws');
              url.pathname = '#{path}';
              var live_view = new WebSocket(url);

              const sparkRenderEvent = new CustomEvent('spark-render');

              live_view.addEventListener('open', (event) => {
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
                // Connection closed
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

            Crinja::SafeString.new(html)
          end
          Registry.register_function(:spark_tag, func)
        end

        private def self.register_live_click : Nil
          filter = Crinja.filter(:live_click) do
            event_name = target.to_s
            Crinja::SafeString.new(%Q(live-click="#{Util.escape_html(event_name)}"))
          end
          Registry.register_filter(:live_click, filter)
        end

        private def self.register_live_change : Nil
          filter = Crinja.filter(:live_change) do
            event_name = target.to_s
            Crinja::SafeString.new(%Q(live-change="#{Util.escape_html(event_name)}"))
          end
          Registry.register_filter(:live_change, filter)
        end

        private def self.register_live_input : Nil
          filter = Crinja.filter(:live_input) do
            event_name = target.to_s
            Crinja::SafeString.new(%Q(live-input="#{Util.escape_html(event_name)}"))
          end
          Registry.register_filter(:live_input, filter)
        end

        private def self.register_live_value : Nil
          filter = Crinja.filter(:live_value) do
            value = target.to_s
            Crinja::SafeString.new(%Q(live-value="#{Util.escape_html(value)}"))
          end
          Registry.register_filter(:live_value, filter)
        end

        private def self.register_component_id : Nil
          filter = Crinja.filter(:component_id) do
            # Try to get ID from component object
            if component = target.raw
              if component.responds_to?(:id)
                component.id.to_s
              else
                target.to_s
              end
            else
              target.to_s
            end
          end
          Registry.register_filter(:component_id, filter)
        end
      end
    end
  end
end
