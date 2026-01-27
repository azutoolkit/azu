require "http"
require "html"
require "../params"
require "./csrf"
require "../helpers/registry"
require "../helpers/util"

module Azu
  # An Endpoint is an endpoint that handles incoming HTTP requests for a specific route.
  # In a Azu application, an endpoint is a simple testable object.
  #
  # This design provides self contained actions that don't share their context
  # accidentally with other actions. It also prevents gigantic controllers.
  # It has several advantages in terms of testability and control of an endpoint.
  #
  # ```
  # module ExampleApp
  #   class UserEndpoint
  #     include Azu::Endpoint(UserRequest, UserResponse)
  #   end
  # end
  # ```
  #
  module Endpoint(Request, Response)
    include HTTP::Handler

    @context : HTTP::Server::Context? = nil
    @params : Params(Request)? = nil
    @request_object : Request? = nil

    # When we include Endpoint module, we make our object compliant with Azu
    # Endpoints by implementing the #call, which is a method that accepts no
    # arguments
    #
    # ```
    # def call : IndexPage
    #   IndexPage.new
    # end
    # ```
    abstract def call : Response

    # :nodoc:
    def call(context : HTTP::Server::Context)
      @context = context
      @params = Params(Request).new(context.request)

      # Set endpoint name header for performance monitoring
      endpoint_name = self.class.name.split("::").last
      context.request.headers["X-Azu-Endpoint"] = endpoint_name

      context.response << call.render
      context
    end

    macro included
      @@resource : String = ""

      def self.path(**params)
        url = @@resource
        params.each { |k, v| url = url.gsub(/\:#{k}/, v) }
        url
      end

      # Calculate resource name for helper generation
      {%
        helper_resource_name = @type.stringify.split("::")
        helper_resource_name = helper_resource_name.size > 1 ? helper_resource_name[-2..-1].join("_") : helper_resource_name.last
        helper_resource_name = helper_resource_name.underscore.gsub(/\_endpoint/, "").id
      %}

      {% for method in Azu::Router::RESOURCES %}
      def self.{{method.id}}(path : Azu::Router::Path)
        @@resource = path
        Azu::CONFIG.router.{{method.id}} path, self.new

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
        }, :link_to_{{method.id}}_{{helper_resource_name}}) do
          id_param = arguments["id"]
          path = if id_param.none?
                   endpoint_class.path
                 else
                   endpoint_class.path(id: id_param.to_s)
                 end

          text = arguments["text"].to_s
          text = path if text.empty?

          attrs = Azu::Helpers::Util.build_html_attributes_from_crinja(arguments, ["text", "id"])
          Crinja::SafeString.new(%(<a href="#{path}"#{attrs}>#{HTML.escape(text)}</a>))
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

          attrs = Azu::Helpers::Util.build_html_attributes_from_crinja(arguments, ["id"])
          Crinja::SafeString.new(%(<form action="#{path}" method="post"#{attrs}>#{method_field}))
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

          Crinja::SafeString.new(<<-HTML
          <form action="#{path}" method="post" style="display:inline"><input type="hidden" name="_method" value="delete"><button type="submit"#{class_attr}#{confirm_attr}>#{HTML.escape(text)}</button></form>
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

      {% request_name = Request.stringify.split("::").last.underscore.downcase.id %}

      def {{request_name}} : Request
        if json = params.json
          Request.from_json json
        else
          Request.from_query params.to_query
        end
      end

      def {{request_name}}_contract : Request
        if json = params.json
          Request.from_json json
        else
          Request.from_query params.to_query
        end
      end
    end

    # Sets the content type for a response
    private def content_type(type : String)
      context.response.content_type = type
    end

    # Gets requests parameters
    # Raises if called before the endpoint is invoked via call(context)
    private def params : Params
      if p = @params
        p
      else
        raise "Endpoint params accessed before initialization. Ensure call(context) was invoked."
      end
    end

    # Gets the request `raw` context
    # Raises if called before the endpoint is invoked via call(context)
    private def context : HTTP::Server::Context
      if ctx = @context
        ctx
      else
        raise "Endpoint context accessed before initialization. Ensure call(context) was invoked."
      end
    end

    # Gets the request http method
    private def method
      Method.parse(context.request.method)
    end

    # Gets the HTTP headers for a request
    private def header
      context.request.headers
    end

    # Gets the request body as json when accepts equals to `application/json`
    private def json
      JSON.parse(body.to_s)
    end

    # Gets the http request cookies
    private def cookies
      context.request.cookies
    end

    # Sets response headers
    private def header(key : String, value : String)
      context.response.headers[key] = value
    end

    # Sets redirect header
    private def redirect(to location : String, status : Int32 = 301)
      status status
      header "Location", location
      Azu::Response::Empty.new
    end

    # Adds http cookie to the response
    private def cookies(cookie : HTTP::Cookie)
      context.response.cookies << cookie
    end

    # Sets http staus to the response
    private def status(status : Int32)
      context.response.status_code = status
    end

    # Defines a an Azu error response
    private def error(message : String, status : Int32 = 400, errors = [] of String)
      Azu::Response::Error.new(message, HTTP::Status.new(status), errors)
    end

    # CSRF Helper Methods

    # Generate CSRF token for the current request
    private def csrf_token : String
      Azu::Handler::CSRF.token(context)
    end

    # Generate CSRF token HTML input tag
    private def csrf_tag : String
      Azu::Handler::CSRF.tag(context)
    end

    # Generate CSRF token meta tag
    private def csrf_metatag : String
      Azu::Handler::CSRF.metatag(context)
    end
  end
end
