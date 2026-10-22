require "json"
require "../markup"
require "../pub_sub"
require "./bindings"
require "./catalog"
require "./coercion"
require "./params"
require "./socket"

module Azu
  module Spark
    # Marks a method as a client event handler; use the `event def` macro instead of
    # annotating by hand.
    annotation Event
    end

    # A stateful, server rendered piece of UI that keeps itself in sync with the browser.
    #
    # ```
    # class Counter < Azu::Spark::Component
    #   mountable
    #
    #   prop label : String = "Clicks" # supplied by the page or the parent, read only
    #   state count : Int32 = 0        # owned by the server, changing it re-renders
    #
    #   def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    #     self.count = params.fetch("start", Int32, 0)
    #   end
    #
    #   event def increment(by : Int32 = 1) : Nil
    #     self.count += by
    #   end
    #
    #   def render
    #     div do
    #       h2 "#{label}: #{count}"
    #       button "+1", **spark_click(:increment)
    #     end
    #   end
    # end
    # ```
    #
    # Everything the client may trigger is declared with `event def`; names and parameter types
    # become a compile time dispatch table, so a client can never invoke any other method and a
    # payload that does not fit the declared types is rejected before the handler runs.
    #
    # Inherit directly from `Azu::Spark::Component`: declarations are not inherited from
    # intermediate component classes.
    abstract class Component
      include Azu::Markup
      include Bindings

      getter! socket : Socket

      def id : String
        socket.id
      end

      # Prepares the component. Runs once on the initial HTTP render (`socket.connected?` is
      # false) and again when the WebSocket joins. Initialise `state`, read `socket.session`,
      # `subscribe` to topics, or refuse the connection with `socket.reject!`.
      def mount(socket : Socket, params : Params) : Nil
      end

      # Handles a PubSub broadcast, a timer (`socket.send_after`, `socket.every`) or a message the
      # component sent itself (`socket.send_info`). The component is rendered afterwards.
      def handle_info(message : PubSub::Message, socket : Socket) : Nil
      end

      # Releases resources when the component leaves the page or the connection closes.
      # Subscriptions and timers are cancelled automatically.
      def unmount(socket : Socket) : Nil
      end

      # Describes the component's HTML with the DSL of `Azu::Markup`.
      abstract def render

      # Typed view of the props and state, for tests and debugging.
      def assigns
        NamedTuple.new
      end

      # :nodoc:
      def handle_event(event : String, params : Params, socket : Socket) : Bool
        false
      end

      # :nodoc:
      def self.__spark_tag : String
        "div"
      end

      # :nodoc:
      def self.__spark_attrs
        NamedTuple.new
      end

      # :nodoc:
      def __spark_snapshot : JSON::Any?
        nil
      end

      # :nodoc:
      def __spark_restore(snapshot : JSON::Any) : Nil
      end

      # :nodoc:
      def __spark_attach(@socket : Socket) : Nil
      end

      # :nodoc:
      def __spark_render : String
        @view = IO::Memory.new
        render
        @view.to_s
      end

      # :nodoc:
      def __spark_open(**extra) : String
        attrs = self.class.__spark_attrs.merge(id: id, "data-spark-id": id, "data-spark-view": self.class.name).merge(extra)
        "<#{self.class.__spark_tag}#{build_attrs(attrs)}>"
      end

      # :nodoc:
      def __spark_close : String
        "</#{self.class.__spark_tag}>"
      end

      # Messages of the validations of *request* (an `Azu::Request`) that failed for *field*.
      private def errors_on(request, field : Symbol) : Array(String)
        request.errors.select { |error| error.field == field }.map(&.message)
      end

      macro inherited
        SPARK_PROPS   = [] of Nil
        SPARK_STATES  = [] of Nil
        SPARK_OPTIONS = {} of Nil => Nil

        macro finished
          __spark_generate
        end
      end

      # Declares a read only input supplied by the page (`Azu::Spark.render`) or the parent
      # component (`live`). A prop without default is required.
      macro prop(declaration)
        {% name = declaration.var %}
        __spark_reserve({{ name }})
        {% SPARK_PROPS << {name: name, type: declaration.type, default: declaration.value} %}
        getter {{ name }} : {{ declaration.type }}
      end

      # Declares server owned state. Assigning a new value (`self.count += 1`) schedules a
      # render. With `persist: true` the value survives reconnects and server restarts inside a
      # signed snapshot kept by the browser, so it must be JSON serializable and not secret.
      macro state(declaration, persist = false)
        {% name = declaration.var %}
        {% raise "state #{name} needs a default value" if declaration.value.is_a?(Nop) %}
        __spark_reserve({{ name }})
        {% SPARK_STATES << {name: name, type: declaration.type, default: declaration.value, persist: persist} %}

        @{{ name }} : {{ declaration.type }} = {{ declaration.value }}

        def {{ name }} : {{ declaration.type }}
          @{{ name }}
        end

        def {{ name }}=(value : {{ declaration.type }}) : {{ declaration.type }}
          unless @{{ name }} == value
            @{{ name }} = value
            @socket.try(&.mark_changed({{ name.stringify }}))
          end
          value
        end
      end

      # Assigns several states at once; names and value types are checked at compile time.
      #
      # ```
      # assign count: 0, step: 5
      # ```
      macro assign(**changes)
        {% for name, value in changes %}
          {% unless SPARK_STATES.any? { |state| state[:name].stringify == name.stringify } %}
            {% raise "#{@type} declares no state named #{name}" %}
          {% end %}
          self.{{ name.id }} = {{ value }}
        {% end %}
      end

      # Declares a method the client may trigger from a binding such as `spark_click`. Parameters
      # are read from the event payload by name and must have a type restriction.
      macro event(definition)
        @[Azu::Spark::Event]
        {{ definition }}

        # :nodoc:
        def __spark_event_{{ definition.name.id }} : Nil
        end
      end

      # Allows rendering this component from a page with `Azu::Spark.render`. Props must be
      # JSON serializable because they travel inside the signed join token.
      macro mountable
        {% SPARK_OPTIONS[:mountable] = true %}
        Azu::Spark::Catalog.register({{ @type.name.stringify }}) do |props|
          {{ @type }}.__spark_from_json(props).as(Azu::Spark::Component)
        end
      end

      # Chooses the element wrapping the component and its static attributes (default `div`),
      # e.g. `container "li", class: "todo"` for a list item.
      macro container(tag, **attributes)
        {% SPARK_OPTIONS[:tag] = tag.id.stringify %}
        {% SPARK_OPTIONS[:attributes] = attributes %}
      end

      # :nodoc:
      macro __spark_reserve(name)
        {% if %w(id socket render mount unmount assigns handle_event handle_info).includes?(name.stringify) %}
          {% raise "`#{name}` is used by Azu::Spark::Component, pick another name" %}
        {% end %}
        {% if Azu::Markup::NON_VOID_TAGS.any? { |tag| tag.id.stringify == name.id.stringify } %}
          # A prop or state named like an HTML tag (`title`, `label`...) keeps working as a value;
          # this overload makes `title do ... end` still build the tag.
          private def {{ name.id }}(**attributes, &block : Proc(Nil)) : Nil
            tag {{ name.id.symbolize }}, **attributes, &block
          end
        {% end %}
      end

      # :nodoc:
      macro __spark_generate
        {% unless @type.abstract? %}
          {% props = SPARK_PROPS %}
          {% states = SPARK_STATES %}

          {% if props.empty? %}
            def initialize
            end
          {% else %}
            def initialize(*, {% for prop in props %}{{ prop[:name] }} : {{ prop[:type] }}{% unless prop[:default].is_a?(Nop) %} = {{ prop[:default] }}{% end %}, {% end %})
              {% for prop in props %}
                @{{ prop[:name] }} = {{ prop[:name] }}
              {% end %}
            end
          {% end %}

          # :nodoc:
          def __spark_assign_props({% unless props.empty? %}*, {% end %}{% for prop in props %}{{ prop[:name] }} : {{ prop[:type] }} = @{{ prop[:name] }}, {% end %}) : Bool
            changed = false
            {% for prop in props %}
              unless {{ prop[:name] }} == @{{ prop[:name] }}
                @{{ prop[:name] }} = {{ prop[:name] }}
                changed = true
              end
            {% end %}
            changed
          end

          def assigns
            {% if props.empty? && states.empty? %}
              NamedTuple.new
            {% else %}
              { {% for prop in props %}{{ prop[:name] }}: @{{ prop[:name] }}, {% end %}{% for state in states %}{{ state[:name] }}: @{{ state[:name] }}, {% end %} }
            {% end %}
          end

          # :nodoc:
          def handle_event(event : String, params : Azu::Spark::Params, socket : Azu::Spark::Socket) : Bool
            {% handlers = [] of Nil %}
            {% for owner in [@type] + @type.ancestors %}
              {% for method in owner.methods %}
                {% handlers << method if method.annotation(Azu::Spark::Event) %}
              {% end %}
            {% end %}
            {% if handlers.empty? %}
              false
            {% else %}
              case event
              {% for method in handlers %}
              when {{ method.name.stringify }}
                {{ method.name.id }}(
                  {% for arg in method.args %}
                    {% raise "event #{method.name}: parameter #{arg.name} needs a type restriction" if arg.restriction.is_a?(Nop) %}
                    {{ arg.name.id }}: params.fetch({{ arg.name.stringify }}, Union({{ arg.restriction }}){% unless arg.default_value.is_a?(Nop) %}, {{ arg.default_value }}{% end %}),
                  {% end %}
                )
                true
              {% end %}
              else
                false
              end
            {% end %}
          end

          {% if SPARK_OPTIONS[:tag] %}
            # :nodoc:
            def self.__spark_tag : String
              {{ SPARK_OPTIONS[:tag] }}
            end

            # :nodoc:
            def self.__spark_attrs
              {% attributes = SPARK_OPTIONS[:attributes] %}
              {% if attributes.empty? %}NamedTuple.new{% else %}{{ attributes }}{% end %}
            end
          {% end %}

          {% if SPARK_OPTIONS[:mountable] %}
            # :nodoc:
            def __spark_props_json : String
              JSON.build do |json|
                json.object do
                  {% for prop in props %}
                    json.field {{ prop[:name].stringify }}, @{{ prop[:name] }}
                  {% end %}
                end
              end
            end

            # :nodoc:
            def self.__spark_from_json(props : JSON::Any) : self
              new(
                {% for prop in props %}
                  {% if prop[:default].is_a?(Nop) %}
                    {{ prop[:name] }}: Union({{ prop[:type] }}).from_json((props[{{ prop[:name].stringify }}]? || raise Azu::Spark::InvalidToken.new("missing prop {{ prop[:name] }}")).to_json),
                  {% else %}
                    {{ prop[:name] }}: (value = props[{{ prop[:name].stringify }}]?) ? Union({{ prop[:type] }}).from_json(value.to_json) : {{ prop[:default] }},
                  {% end %}
                {% end %}
              )
            end
          {% end %}

          {% persisted = states.select { |state| state[:persist] } %}
          {% unless persisted.empty? %}
            # :nodoc:
            def __spark_snapshot : JSON::Any?
              JSON.parse(JSON.build do |json|
                json.object do
                  {% for state in persisted %}
                    json.field {{ state[:name].stringify }}, @{{ state[:name] }}
                  {% end %}
                end
              end)
            end

            # :nodoc:
            def __spark_restore(snapshot : JSON::Any) : Nil
              {% for state in persisted %}
                if value = snapshot[{{ state[:name].stringify }}]?
                  @{{ state[:name] }} = Union({{ state[:type] }}).from_json(value.to_json)
                end
              {% end %}
            end
          {% end %}
        {% end %}
      end
    end
  end
end
