require "html"
require "uuid"

module Azu
  # Thread-safe component registry with pooling support
  class ComponentRegistry
    @components = {} of String => Component
    @mutex = Mutex.new
    @pool = {} of String => Array(Component)
    @pool_mutex = Mutex.new
    @max_pool_size : Int32 = 50
    @topics = {} of String => Set(String)
    @topics_mutex = Mutex.new

    def initialize(@max_pool_size : Int32 = 50)
    end

    # Adds the component *id* to *topic*.
    def subscribe(topic : String, id : String) : Nil
      @topics_mutex.synchronize do
        (@topics[topic] ||= Set(String).new) << id
      end
    end

    # Removes the component *id* from *topic*.
    def unsubscribe(topic : String, id : String) : Nil
      @topics_mutex.synchronize do
        if ids = @topics[topic]?
          ids.delete(id)
          @topics.delete(topic) if ids.empty?
        end
      end
    end

    # Removes the component *id* from every topic.
    def unsubscribe_all(id : String) : Nil
      @topics_mutex.synchronize do
        @topics.reject! do |_, ids|
          ids.delete(id)
          ids.empty?
        end
      end
    end

    # Sends *event* with *data* to every component subscribed to *topic*.
    # Returns the number of components reached.
    def publish(topic : String, event : String, data : String = "") : Int32
      ids = @topics_mutex.synchronize { @topics[topic]?.try(&.to_a) || [] of String }
      reached = 0
      ids.each do |id|
        if component = get(id)
          component.on_event(event, data)
          reached += 1
        end
      end
      reached
    end

    # Unmounts and removes only the components in *ids*.
    def cleanup(ids : Enumerable(String)) : Nil
      removed = [] of Component
      @mutex.synchronize do
        ids.each { |id| @components.delete(id).try { |component| removed << component } }
      end
      removed.each do |component|
        component.unmount
        return_to_pool(component)
      end
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

    # Type-safe component retrieval with compile-time type checking
    # Returns nil if component doesn't exist or is not of the expected type
    #
    # Example:
    # ```
    # if counter = registry.get_typed("counter_1", CounterComponent)
    #   counter.increment # No cast needed, type is CounterComponent
    # end
    # ```
    def get_typed(id : String, type : T.class) : T? forall T
      if component = get(id)
        component.as?(T)
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
    def get_from_pool(type : String, & : -> Component) : Component
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
    # Support both class-level (backward compatibility) and instance-level registries
    @@default_registry : ComponentRegistry? = nil
    @@registry_mutex = Mutex.new
    GC_INTERVAL = 10.seconds

    gc_sweep

    # Get the default class-level registry (backward compatibility)
    def self.components
      @@registry_mutex.synchronize do
        @@default_registry ||= ComponentRegistry.new
      end
    end

    # Reset the default registry (useful for testing)
    def self.reset_registry!
      @@registry_mutex.synchronize do
        @@default_registry = nil
      end
    end

    # Instance-level registry for dependency injection
    @components : ComponentRegistry

    # Components this socket subscribed to; only these are removed when it closes.
    @subscribed = Set(String).new

    # Sends *event* to every component subscribed to *topic* with `subscribe "topic"`;
    # they handle it with `on :event`. Returns how many components were reached.
    #
    # ```
    # Azu::Spark.broadcast("room:1", "message", "Hello!")
    # ```
    def self.broadcast(topic : String, event : String, data : String = "") : Int32
      components.publish(topic, event, data)
    end

    def initialize(socket : HTTP::WebSocket, @components : ComponentRegistry = Spark.components)
      super(socket)
    end

    # The client script as a `<script type="module">` tag (no dependencies). *path* is
    # the route of the `Azu::Spark` channel, `/spark` by default.
    #
    # ```
    # Azu::Spark.javascript_tag          # in a layout
    # Azu::Spark.javascript_tag("/live") # when the channel is mounted elsewhere
    # ```
    def self.javascript_tag(path : String = "/spark") : String
      %(<script type="module" data-spark-path="#{HTML.escape(path)}">\n#{javascript_source}\n</script>)
    end

    # The client script source (`js/azu-spark.js`), embedded at compile time.
    def self.javascript_source : String
      {{ read_file("#{__DIR__}/../../js/azu-spark.js") }}
    end

    private def self.gc_sweep
      spawn do
        loop do
          sleep GC_INTERVAL
          if registry = @@default_registry
            registry.cleanup_disconnected(GC_INTERVAL)
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
      @components.cleanup(@subscribed)
      @subscribed.clear
    end

    def on_message(message)
      json = JSON.parse(message)
      handle_message(json)
    rescue ex : IO::Error
      log_error("WebSocket IO error", ex, severity: :debug)
    rescue ex : JSON::ParseException
      log_error("Invalid JSON from client", ex, severity: :warn)
    rescue ex : KeyError
      log_error("Incomplete event message", ex, severity: :warn)
    rescue ex
      log_error("Unexpected error in message handler", ex, severity: :error)
    end

    private def handle_message(json : JSON::Any)
      if channel = json["subscribe"]?
        handle_subscribe_message(channel.to_s)
      elsif event_name = json["event"]?
        handle_event_message(json, event_name.as_s)
      end
    end

    private def handle_subscribe_message(spark : String)
      if component = @components.get(spark)
        @subscribed << spark
        component.connected = true
        component.socket = socket
        component.mount
      end
    end

    private def handle_event_message(json : JSON::Any, event_name : String)
      if channel = json["channel"]?
        spark = channel.to_s
        data = json["data"]?.try(&.as_s) || ""
        if component = @components.get(spark)
          component.on_event(event_name, data)
        end
      end
    end

    private def log_error(description : String, ex : Exception,
                          severity : Symbol = :error)
      log = Log.for("Azu::Spark")
      case severity
      when :debug then log.debug(exception: ex) { description }
      when :warn  then log.warn(exception: ex) { description }
      when :error then log.error(exception: ex) { description }
      end
    end
  end
end
