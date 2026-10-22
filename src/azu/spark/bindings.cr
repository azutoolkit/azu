module Azu
  module Spark
    # Reactive attributes for the HTML DSL. Each macro returns a named tuple of `spark-*`
    # attributes meant to be double splatted into a tag; the client script turns them into
    # events for the component the element belongs to:
    #
    # ```
    # button "Delete", **spark_click(:remove, id: todo.id, confirm: "Sure?")
    # input **spark_change(:search, debounce: 300), type: "text", name: "q"
    # form(**spark_submit(:save)) { ... }
    # ```
    #
    # Crystal requires double splats to come before named arguments: write
    # `button "+", **spark_click(:inc), class: "btn"`, not the other way round.
    #
    # The event must be declared with `event def` in the component, otherwise compilation fails.
    # Options:
    # - `debounce: ms` / `throttle: ms` rate limit the event in the browser
    # - `target: :parent | :root | "css selector"` sends it to another component
    # - `key: "Enter"` only fires keyboard events for that key
    # - `confirm: "text"` asks the user first
    # - `disable_with: "Saving..."` swaps the element's text while the event is in flight
    # - `optimistic_class: "done"` adds a CSS class immediately; the server render is authoritative
    # - any other option is sent to the handler as a parameter (`id: 3` reaches `def remove(id : Int64)`)
    module Bindings
      MODIFIERS = %w(debounce throttle target key confirm disable_with optimistic_class)

      macro spark_click(event, **options)
        __spark_binding(:click, {{ event }}, {{ options.double_splat }})
      end

      macro spark_submit(event, **options)
        __spark_binding(:submit, {{ event }}, {{ options.double_splat }})
      end

      # Fires on every edit of the control (or of any control inside the element, for forms).
      macro spark_change(event, **options)
        __spark_binding(:change, {{ event }}, {{ options.double_splat }})
      end

      macro spark_keydown(event, **options)
        __spark_binding(:keydown, {{ event }}, {{ options.double_splat }})
      end

      macro spark_keyup(event, **options)
        __spark_binding(:keyup, {{ event }}, {{ options.double_splat }})
      end

      macro spark_blur(event, **options)
        __spark_binding(:blur, {{ event }}, {{ options.double_splat }})
      end

      macro spark_focus(event, **options)
        __spark_binding(:focus, {{ event }}, {{ options.double_splat }})
      end

      # :nodoc:
      macro __spark_binding(kind, event, **options)
        {% name = event.id.stringify %}
        {% if @type.class? && !options[:target] && !@type.has_method?("__spark_event_#{name.id}") %}
          {% raise "#{@type} does not declare `event def #{name.id}`, so spark_#{kind.id}(:#{name.id}) can never be handled" %}
        {% end %}
        {
          "spark-{{ kind.id }}": {{ name }},
          {% for key, value in options %}
            {% attr = key.stringify.gsub(/_/, "-") %}
            {% if MODIFIERS.includes?(key.stringify) %}
              "spark-{{ attr.id }}": {{ value }},
            {% else %}
              "spark-value-{{ attr.id }}": {{ value }},
            {% end %}
          {% end %}
        }
      end

      # Embeds the child component *type*. *key* identifies it among its siblings across renders;
      # the props are checked against the child's `prop` declarations at compile time.
      #
      # ```
      # todos.each { |todo| live TodoItem, key: todo.id.to_s, todo: todo }
      # ```
      private def live(type : T.class, key : String, **props) : Nil forall T
        raw socket.child(type, key, **props)
      end
    end
  end
end
