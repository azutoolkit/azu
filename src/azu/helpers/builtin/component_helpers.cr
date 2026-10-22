module Azu
  module Helpers
    module Builtin
      # Component helpers for templates.
      #
      # The Spark client script is installed by the application (`Azu::Spark.script_tag`);
      # reactive attributes come from the `Azu::Spark::Component` DSL, not from template filters.
      module ComponentHelpers
        def self.register : Nil
          register_component_id
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
