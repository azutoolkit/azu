require "uuid"

module Azu
  # Thread-safe component registry with pooling support
  class ComponentRegistry
    @components = {} of String => Component
    @mutex = Mutex.new
    @pool = {} of String => Array(Component)
    @pool_mutex = Mutex.new
    @max_pool_size : Int32 = 50

    def initialize(@max_pool_size : Int32 = 50)
    end

    # Thread-safe component registration
    def register(id : String, component : Component) : Nil
      @mutex.synchronize do
        @components[id] = component
      end
    end

    # Thread-safe component retrieval
    def get(id : String) : Component?
      @mutex.synchronize do
        @components[id]?
      end
    end

    # Thread-safe component removal
    def delete(id : String) : Component?
      @mutex.synchronize do
        @components.delete(id)
      end
    end

    # Thread-safe iteration with cleanup
    def cleanup_disconnected(gc_interval : Time::Span) : Nil
      to_remove = [] of String

      @mutex.synchronize do
        @components.each do |id, component|
          if component.disconnected? && (component.mounted? || component.age > gc_interval)
            to_remove << id
          end
        end

        to_remove.each do |id|
          if component = @components.delete(id)
            return_to_pool(component)
          end
        end
      end
    end

    # Thread-safe component cleanup on close
    def cleanup_all : Nil
      components_to_cleanup = [] of Component

      @mutex.synchronize do
        components_to_cleanup = @components.values
        @components.clear
      end

      # Unmount outside of mutex to avoid holding lock too long
      components_to_cleanup.each do |component|
        component.unmount
        return_to_pool(component)
      end
    end

        # Get component from pool or create new one
    def get_from_pool(type : String, &block : -> Component) : Component
      @pool_mutex.synchronize do
        if (pool = @pool[type]?) && !pool.empty?
          component = pool.pop
          component.reset_for_reuse
          return component
        end
      end

      # Create new component if pool is empty
      yield
    end

    # Return component to pool for reuse
    private def return_to_pool(component : Component) : Nil
      type = component.class.name

      @pool_mutex.synchronize do
        pool = (@pool[type] ||= [] of Component)
        if pool.size < @max_pool_size
          component.prepare_for_pool
          pool << component
        end
      end
    end

    # Get current component count (for monitoring)
    def size : Int32
      @mutex.synchronize do
        @components.size
      end
    end
  end

  class Spark < Channel
    # Use thread-safe component registry instead of global hash
    @@components = ComponentRegistry.new
    GC_INTERVAL = 10.seconds

    gc_sweep

    def self.components
      @@components
    end

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
          @@components.cleanup_disconnected(GC_INTERVAL)
        end
      end
    end

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code : HTTP::WebSocket::CloseCode? = nil, message : String? = nil)
      @@components.cleanup_all
    end

    def on_message(message)
      json = JSON.parse(message)

      if channel = json["subscribe"]?
        spark = channel.to_s
        if component = @@components.get(spark)
          component.connected = true
          component.socket = socket
          component.mount
        end
      elsif event_name = json["event"]?
        spark = json["channel"].not_nil!.to_s
        data = json["data"].not_nil!.as_s
        if component = @@components.get(spark)
          component.on_event(event_name.as_s, data)
        end
      end
    rescue IO::Error
    rescue ex
      ex.inspect STDERR
    end
  end
end
