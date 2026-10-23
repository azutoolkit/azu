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
      #   <button {{ "increment" | spark_click }}>+</button>
      #   <input type="text" {{ "search" | spark_input }} />
      #   <form {{ "save" | spark_submit }}>...</form>
      # </body>
      # ```
      module ComponentHelpers
        def self.register : Nil
          register_spark_tag
          register_spark_click
          register_spark_change
          register_spark_input
          register_spark_submit
          register_spark_value
          register_live_click
          register_live_change
          register_live_input
          register_live_value
          register_component_id
        end

        private def self.register_spark_tag : Nil
          func = Crinja.function({
            path:   "/spark",
            jquery: false,
          }, :spark_tag) do
            # `jquery` is accepted for old templates; the client no longer needs it.
            Crinja::SafeString.new(Azu::Spark.javascript_tag(arguments["path"].to_s))
          end
          Registry.register_function(:spark_tag, func)
        end

        {% for name in %w(click change input submit) %}
          private def self.register_spark_{{name.id}} : Nil
            filter = Crinja.filter(:spark_{{name.id}}) do
              Crinja::SafeString.new(%Q(spark-{{name.id}}="#{Util.escape_html(target.to_s)}"))
            end
            Registry.register_filter(:spark_{{name.id}}, filter)
          end
        {% end %}

        private def self.register_spark_value : Nil
          filter = Crinja.filter(:spark_value) do
            Crinja::SafeString.new(%Q(spark-value="#{Util.escape_html(target.to_s)}"))
          end
          Registry.register_filter(:spark_value, filter)
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
