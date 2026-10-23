require "./markup"
require "uuid"
require "json"
require "http/web_socket"

# Conditionally require performance metrics only when enabled
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  require "./performance_metrics"
{% end %}

module Azu
  # A live component: server-side state and markup that re-renders over a WebSocket
  # (see `Azu::Spark`).
  #
  # ```
  # class Counter
  #   include Azu::Component
  #
  #   prop label : String = "Count" # set once, from `Counter.mount(label: "Hits")`
  #   state count : Int32 = 0       # changing it re-renders the component
  #
  #   on :increment do
  #     self.count += 1
  #   end
  #
  #   on :set do |event|
  #     self.count = event.value.to_i
  #   end
  #
  #   def content
  #     div do
  #       h2 { text "#{label}: #{count}" }
  #       button(spark_click: :increment) { text "+" }
  #       input(type: "number", value: count, spark_change: :set)
  #     end
  #   end
  # end
  #
  # Counter.mount(label: "Hits") # => a registered component; put `.render` in a page
  # ```
  #
  # ## Declaring data
  #
  # * `prop name : Type [= default]`: read-only data given to `mount`/`new`.
  # * `state name : Type [= default]`: data that changes. Assigning a different value
  #   re-renders the component, once per event however many assignments the handler makes.
  # * `assign(name: value, ...)`: assigns several states at once (checked at compile time).
  # * `changed!`: re-render after mutating a state in place (`items << x`).
  #
  # ## Handling events
  #
  # `on :name do |event| ... end` handles `spark_click: :name`, `spark_change: :name`,
  # `spark_submit: :name`, ... from the markup, and events sent with
  # `Azu::Spark.broadcast`. `event.value`, `event["field"]`, `event.checked?` and
  # `event.to_h` read the payload; `on :save, SignupForm do |form|` parses it into a
  # `JSON::Serializable` type (e.g. an `Azu::Request`) for you.
  #
  # ## Markup attributes
  #
  # | attribute                   | sends                                                  |
  # | --------------------------- | ------------------------------------------------------ |
  # | `spark_click: :event`       | on click                                               |
  # | `spark_change: :event`      | on change (blur/enter for text inputs, toggle, select) |
  # | `spark_input: :event`       | on every keystroke                                     |
  # | `spark_submit: :event`      | on form submit, with all fields                        |
  # | `spark_keydown: :event`     | on key down, optionally `spark_key: "Enter"`           |
  # | `spark_value: "x"`          | the value to send for buttons and links                |
  # | `spark_debounce: 300`       | wait (ms) after the last input before sending          |
  # | `spark_target: "component-id"` | deliver to another component                       |
  #
  # ## Lifecycle
  #
  # `after_mount { ... }` runs when the browser connects (start timers with
  # `every(5.seconds) { ... }`, join topics with `subscribe "room:1"`), and
  # `before_unmount { ... }` when it goes away.
  module Component
    include Markup

    # A message from the browser (or from `Azu::Spark.broadcast`) to a component.
    class Event
      getter data : String
      @json : JSON::Any? = nil

      def initialize(@data : String = "")
      end

      # The payload parsed as JSON; a payload that is not JSON is the String itself.
      def json : JSON::Any
        @json ||= begin
          JSON.parse(@data)
        rescue JSON::ParseException
          JSON::Any.new(@data)
        end
      end

      # The `value` of the event: the input value, the checkbox state or the `spark_value`.
      # Falls back to the whole payload.
      def value : String
        parsed = json
        if hash = parsed.as_h?
          hash["value"]?.try(&.raw.to_s) || ""
        else
          parsed.raw.to_s
        end
      end

      # True when the event came from a checked checkbox or carries `true`.
      def checked? : Bool
        json.as_h?.try(&.["value"]?.try(&.raw)) == true || json.raw == true
      end

      # A field of a submitted form or event payload.
      def []?(key : String | Symbol) : String?
        json.as_h?.try(&.[key.to_s]?).try(&.raw.to_s)
      end

      def [](key : String | Symbol) : String
        self[key]? || raise KeyError.new("Missing event field: #{key}")
      end

      # All top-level fields as strings.
      def to_h : Hash(String, String)
        fields = Hash(String, String).new
        json.as_h?.try &.each { |key, item| fields[key] = item.raw.to_s }
        fields
      end

      # Parses the payload into *type*, e.g. a `JSON::Serializable` struct.
      def parse(type : T.class) : T forall T
        T.from_json(@data)
      end
    end

    property? mounted = false
    property? connected = false
    getter id : String = UUID.random.to_s

    @socket : HTTP::WebSocket? = nil
    @created_at = Time.utc
    @performance_tracking_enabled = false
    @dirty = false
    @batch_depth = 0

    getter socket

    macro included
      SPARK_FIELDS = [] of Nil

      def self.mount(**args)
        component = new **args
        component.track("mount") do
          component.mounted = true
          Azu::Spark.components.register(component.id, component)
        end
        component
      end

      macro finished
        spark_define_members
      end

      macro inherited
        SPARK_FIELDS = [] of Nil

        macro finished
          spark_define_members
        end
      end
    end

    # Declares read-only data supplied when the component is created.
    #
    # ```
    # prop title : String = "Untitled"
    # prop user : User # required: `Card.mount(user: current_user)`
    # ```
    macro prop(decl)
      {% unless decl.is_a?(TypeDeclaration) %}
        {% decl.raise "prop expects a typed declaration, e.g. `prop title : String = \"Untitled\"`" %}
      {% end %}
      {% SPARK_FIELDS << {name: decl.var.id, type: decl.type, default: decl.value, kind: "prop"} %}
      getter {{decl}}
    end

    # Declares data that can change. Assigning a different value re-renders the component.
    #
    # ```
    # state count : Int32 = 0
    #
    # on :increment do
    #   self.count += 1 # re-renders once the handler returns
    # end
    # ```
    macro state(decl)
      {% unless decl.is_a?(TypeDeclaration) %}
        {% decl.raise "state expects a typed declaration, e.g. `state count : Int32 = 0`" %}
      {% end %}
      {% SPARK_FIELDS << {name: decl.var.id, type: decl.type, default: decl.value, kind: "state"} %}
      getter {{decl}}

      def {{decl.var.id}}=(value : {{decl.type}}) : {{decl.type}}
        unless @{{decl.var.id}} == value
          @{{decl.var.id}} = value
          state_changed!
        end
        value
      end
    end

    # Assigns several states at once and re-renders once. A misspelled name is a
    # compile-time error.
    #
    # ```
    # assign count: 0, label: "Reset"
    # ```
    macro assign(**states)
      batch do
        {% for name, value in states %}
          self.{{name.id}} = {{value}}
        {% end %}
      end
    end

    # Handles the event *name* sent by `spark_click: :name`, `spark_submit: :name`, ...
    # or by `Azu::Spark.broadcast`. Re-renders afterwards if a state changed.
    #
    # ```
    # on :increment { self.count += 1 }
    # on(:rename) { |event| self.title = event.value }
    # on :signup, SignupForm do |form| # payload parsed into SignupForm
    #   self.errors = form_errors(form)
    # end
    # ```
    macro on(name, type = nil, &block)
      {% unless name.is_a?(SymbolLiteral) || name.is_a?(StringLiteral) %}
        {% name.raise "on expects an event name like `on :increment`, got `#{name}`" %}
      {% end %}
      {% arg = block.args.size > 0 ? block.args[0].id : "event".id %}
      def __spark_on_{{name.id}}(%event : Azu::Component::Event) : Nil
        {% if type %}
          {{arg}} = %event.parse({{type}})
        {% else %}
          {{arg}} = %event
        {% end %}
        {{block.body}}
      end
    end

    # Runs the block when the browser connects to the component.
    #
    # ```
    # after_mount do
    #   every(1.second) { self.seconds += 1 }
    # end
    # ```
    macro after_mount(&block)
      def on_mount : Nil
        super
        {{block.body}}
      end
    end

    # Runs the block when the component is removed.
    macro before_unmount(&block)
      def on_unmount : Nil
        {{block.body}}
        super
      end
    end

    # :nodoc:
    macro spark_define_members
      {%
        fields = [] of Nil
        klass = @type
        chain = [] of Nil
        (0..8).each do |_|
          if klass && klass.has_constant?("SPARK_FIELDS")
            chain << klass
            klass = klass.superclass
          end
        end
        (0...chain.size).each do |i|
          chain[chain.size - 1 - i].constant("SPARK_FIELDS").each { |field| fields << field }
        end
        own_methods = @type.methods.map(&.name.stringify)
        events = own_methods.select(&.starts_with?("__spark_on_")).map { |m| m["__spark_on_".size..-1] }
      %}

      {% if !fields.empty? && !own_methods.includes?("initialize") %}
        def initialize(*, {% for field in fields %}{{field[:name]}} : {{field[:type]}}{% unless field[:default].is_a?(Nop) %} = {{field[:default]}}{% end %}, {% end %})
          {% for field in fields %}
            @{{field[:name]}} = {{field[:name]}}
          {% end %}
        end
      {% end %}

      {% if !events.empty? %}
        # :nodoc:
        def __spark_dispatch(name : String, data : String) : Bool
          case name
          {% for event in events %}
            when {{event}}
              __spark_on_{{event.id}}(Azu::Component::Event.new(data))
              true
          {% end %}
          else
            super
          end
        end
      {% end %}
    end

    def disconnected?
      !connected?
    end

    def age
      Time.utc - @created_at
    end

    # Called when the browser has connected to the component. Prefer `after_mount { }`.
    def on_mount : Nil
    end

    # Called when the component goes away. Prefer `before_unmount { }`.
    def on_unmount : Nil
    end

    def mount
      track("mount") do
        @mounted = true
        batch { on_mount }
      end
    end

    def unmount
      track("unmount") do
        @mounted = false
        on_unmount
        Azu::Spark.components.unsubscribe_all(@id)
      end
    end

    # :nodoc:
    def __spark_dispatch(name : String, data : String) : Bool
      false
    end

    # Receives an event by name. The default dispatches to the handlers declared with
    # `on`; override it for hand-written handling.
    def on_event(name, data)
      track("event_handler:#{name}") do
        batch { __spark_dispatch(name.to_s, data.to_s) }
      end
    end

    def content
    end

    def refresh
      track("refresh") do
        content
        if socket = @socket
          json = {content: to_s, id: id}.to_json
          socket.send json
          # Only clear the view after sending to socket
          @view = IO::Memory.new
        end
        # Don't clear the view if there's no socket, so content remains available
      end
    end

    def refresh(&)
      yield
      refresh
    end

    # Runs the block, then re-renders once if any state changed. Event handlers and
    # `every` blocks are batched already.
    def batch(&)
      @batch_depth += 1
      begin
        yield
      ensure
        @batch_depth -= 1
      end
      flush_changes
    end

    # Marks the component as changed so it re-renders; use after mutating a state in place.
    def changed! : Nil
      state_changed!
    end

    # :nodoc:
    def state_changed! : Nil
      @dirty = true
      flush_changes if @batch_depth == 0
    end

    # Runs the block every *duration* while the browser is connected.
    def every(duration : Time::Span, &block)
      spawn do
        while connected?
          sleep duration
          batch { block.call } if connected?
        end
      rescue IO::Error
        # This happens when a socket closes at just the right time
      rescue ex
        ex.inspect STDERR
      end
    end

    # Runs the block in its own fiber, then re-renders if a state changed. Use it for
    # slow work so the event handler returns right away.
    #
    # ```
    # on :search do |event|
    #   self.loading = true
    #   defer { self.results = Search.run(event.value); self.loading = false }
    # end
    # ```
    def defer(&block)
      spawn do
        batch { block.call }
      rescue IO::Error
        # The socket closed meanwhile
      rescue ex
        ex.inspect STDERR
      end
    end

    # Joins *topic*: events sent with `Azu::Spark.broadcast(topic, ...)` reach `on` handlers.
    def subscribe(topic : String) : Nil
      Azu::Spark.components.subscribe(topic, @id)
    end

    def unsubscribe(topic : String) : Nil
      Azu::Spark.components.unsubscribe(topic, @id)
    end

    # Field name => messages for a form that includes `Azu::Request`, ready to store in a state.
    #
    # ```
    # on :validate, SignupForm do |form|
    #   self.errors = form_errors(form)
    # end
    # ```
    def form_errors(form) : Hash(String, Array(String))
      found = Hash(String, Array(String)).new
      form.errors.each { |error| (found[error.field.to_s] ||= [] of String) << error.message }
      found
    end

    def socket=(other)
      @socket = other
    end

    def render
      content
      <<-HTML
      <div data-spark-view="#{id}">
        <div>#{to_s}</div>
      </div>
      HTML

    ensure
      @view = IO::Memory.new
    end

    # Component pooling methods for memory optimization
    def reset_for_reuse
      @mounted = false
      @connected = false
      @socket = nil
      @created_at = Time.utc
      @view = IO::Memory.new
      generate_new_id
    end

    def prepare_for_pool
      unmount
      @socket = nil
      @connected = false
      # Clear any component-specific state that shouldn't persist
      @view = IO::Memory.new
    end

    # Enable performance tracking for this component
    def enable_performance_tracking
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        @performance_tracking_enabled = true
      {% end %}
    end

    # Disable performance tracking for this component
    def disable_performance_tracking
      @performance_tracking_enabled = false
    end

    # Times the block and reports it to the performance monitor when monitoring is
    # compiled in and enabled; otherwise it only yields.
    #
    # :nodoc:
    def track(event : String, &)
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        start_time = Time.instant
        memory_before = nil
        if @performance_tracking_enabled
          memory_before = Azu::PerformanceMetrics.current_memory_usage
        end

        result = yield

        if @performance_tracking_enabled && Azu::CONFIG.performance_enabled?
          processing_time = (Time.instant - start_time).total_milliseconds
          memory_after = Azu::PerformanceMetrics.current_memory_usage

          if monitor = Azu::CONFIG.performance_monitor
            monitor.metrics.record_component(
              component_id: @id,
              component_type: self.class.name,
              event: event,
              processing_time: processing_time,
              memory_before: memory_before,
              memory_after: memory_after,
              age_at_event: age
            )
          end
        end

        result
      {% else %}
        yield
      {% end %}
    end

    private def flush_changes : Nil
      return unless @dirty
      @dirty = false
      refresh if connected?
    end

    private def generate_new_id
      @id = UUID.random.to_s
    end
  end
end
