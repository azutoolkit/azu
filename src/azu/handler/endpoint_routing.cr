require "../routes"

module Azu
  module EndpointHelpers
    # Registers the HTTP verb class methods (`get`, `post`, ...), the Crinja link/form
    # helpers and the `*_path` filter for the type it is expanded in. It is shared by
    # `Azu::Endpoint` (via `inherited`) and the legacy `Azu::Action` (via `included`),
    # both of which include this module so the macro is in scope.
    #
    # ```
    # get "/users/:id", as: :user # => also registers the `:user` named route
    # ```
    macro define_endpoint_routes
      @@resource : String = ""

      def self.path(**params)
        Azu::Routes.expand(@@resource, **params)
      end

      # Calculate resource name for helper generation
      {%
        helper_resource_name = @type.stringify.split("::")
        helper_resource_name = helper_resource_name.size > 1 ? helper_resource_name[-2..-1].join("_") : helper_resource_name.last
        helper_resource_name = helper_resource_name.underscore.gsub(/\_endpoint/, "").id
      %}

      {% for method in Azu::Router::RESOURCES %}
      def self.{{method.id}}(path : Azu::Router::Path, as route_name : Symbol | String | Nil = nil, router : Azu::Router = Azu::CONFIG.router)
        @@resource = path
        Azu::Routes.register(route_name, path) if route_name
        router.{{method.id}} path, self.new

        # Register type-safe link helper: link_to_{method}_{resource}
        _register_link_helper_{{method.id}}
        {% if method != "get" %}
        # Register type-safe form helper: form_for_{method}_{resource}
        _register_form_helper_{{method.id}}
        {% end %}
        {% if method == "delete" %}
        # Register button_to_delete helper
        _register_button_to_delete_helper
        {% end %}
      end

      # Link helper registration for {{method.id}}
      private def self._register_link_helper_{{method.id}}
        endpoint_class = self
        func = Crinja.function({
          text:   "",
          id:     nil,
          class:  nil,
          target: nil,
          data:   nil,
          params: nil,
        }, :link_to_{{method.id}}_{{helper_resource_name}}) do
          id_param = arguments["id"]
          path = if id_param.none?
                   endpoint_class.path
                 else
                   endpoint_class.path(id: id_param.to_s)
                 end

          # Handle custom URL query parameters
          params_arg = arguments["params"]
          unless params_arg.none?
            query_parts = [] of String
            if params_arg.raw.is_a?(Hash)
              params_arg.raw.as(Hash).each do |k, v|
                query_parts << "#{URI.encode_www_form(k.to_s)}=#{URI.encode_www_form(v.to_s)}"
              end
            end
            unless query_parts.empty?
              separator = path.includes?("?") ? "&" : "?"
              path = "#{path}#{separator}#{query_parts.join("&")}"
            end
          end

          text = arguments["text"].to_s
          text = path if text.empty?

          attrs = Azu::Helpers::Util.build_html_attributes_from_crinja(arguments, ["text", "id", "params"])
          Crinja::SafeString.new(%(<a href="#{HTML.escape(path)}"#{attrs}>#{HTML.escape(text)}</a>))
        end
        Azu::Helpers::Registry.register_function(:link_to_{{method.id}}_{{helper_resource_name}}, func)
      end

      {% if method != "get" %}
      # Form helper registration for {{method.id}}
      private def self._register_form_helper_{{method.id}}
        endpoint_class = self
        func = Crinja.function({
          id:      nil,
          class:   nil,
          enctype: nil,
          data:    nil,
          params:  nil,
        }, :form_for_{{method.id}}_{{helper_resource_name}}) do
          id_param = arguments["id"]
          path = if id_param.none?
                   endpoint_class.path
                 else
                   endpoint_class.path(id: id_param.to_s)
                 end

          # Always use POST for form method, add _method hidden field for PUT/PATCH/DELETE
          http_method = "{{method.id}}"
          method_field = ""
          if http_method.in?("put", "patch", "delete")
            method_field = %(<input type="hidden" name="_method" value="#{http_method}">)
          end

          # Handle custom params as hidden fields
          params_arg = arguments["params"]
          hidden_fields = ""
          unless params_arg.none?
            if params_arg.raw.is_a?(Hash)
              params_arg.raw.as(Hash).each do |k, v|
                hidden_fields += %(<input type="hidden" name="#{HTML.escape(k.to_s)}" value="#{HTML.escape(v.to_s)}">)
              end
            end
          end

          attrs = Azu::Helpers::Util.build_html_attributes_from_crinja(arguments, ["id", "params"])
          Crinja::SafeString.new(%(<form action="#{HTML.escape(path)}" method="post"#{attrs}>#{method_field}#{hidden_fields}))
        end
        Azu::Helpers::Registry.register_function(:form_for_{{method.id}}_{{helper_resource_name}}, func)
      end
      {% end %}

      {% if method == "delete" %}
      # Button to delete helper registration
      private def self._register_button_to_delete_helper
        endpoint_class = self
        func = Crinja.function({
          text:    "Delete",
          id:      nil,
          class:   nil,
          confirm: nil,
          data:    nil,
          params:  nil,
        }, :button_to_delete_{{helper_resource_name}}) do
          id_param = arguments["id"]
          path = if id_param.none?
                   endpoint_class.path
                 else
                   endpoint_class.path(id: id_param.to_s)
                 end

          text = arguments["text"].to_s
          text = "Delete" if text.empty?

          confirm_val = arguments["confirm"]
          confirm_attr = confirm_val.none? ? "" : %( onclick="return confirm('#{HTML.escape(confirm_val.to_s)}')")

          css_class = arguments["class"]
          class_attr = css_class.none? ? "" : %( class="#{HTML.escape(css_class.to_s)}")

          # Handle custom params as hidden fields
          params_arg = arguments["params"]
          hidden_fields = ""
          unless params_arg.none?
            if params_arg.raw.is_a?(Hash)
              params_arg.raw.as(Hash).each do |k, v|
                hidden_fields += %(<input type="hidden" name="#{HTML.escape(k.to_s)}" value="#{HTML.escape(v.to_s)}">)
              end
            end
          end

          Crinja::SafeString.new(<<-HTML
          <form action="#{HTML.escape(path)}" method="post" style="display:inline"><input type="hidden" name="_method" value="delete">#{hidden_fields}<button type="submit"#{class_attr}#{confirm_attr}>#{HTML.escape(text)}</button></form>
          HTML
          )
        end
        Azu::Helpers::Registry.register_function(:button_to_delete_{{helper_resource_name}}, func)
      end
      {% end %}
      {% end %}

      # Registers crinja path helper filters
      {%
        resource_name = @type.stringify.split("::")
        resource_name = resource_name.size > 1 ? resource_name[-2..-1].join("_") : resource_name.last
        resource_name = resource_name.underscore.gsub(/\_endpoint/, "").id
      %}
      Azu::CONFIG.templates.crinja.filters[:{{resource_name}}_path] = Crinja.filter({id: nil}) do
        {{@type.name.id}}.path(id: arguments["id"])
      end

      def self.helper_path_name
        :{{resource_name}}_path
      end

  end
  end
end
