require "http"
require "html"
require "../params"
require "./csrf"
require "../routable"
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
    include Routable

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

    # The operation the OpenAPI document describes this endpoint with, built from `Request` and `Response`.
    def openapi_operation : OpenAPI::Operation?
      OpenAPI::Operation.of(self.class, Request, Response)
    end

    # :nodoc:
    #
    # The router holds one instance per route. A struct is copied on dispatch; a class is copied here, so
    # concurrent requests never share the per-request state (`@context`, `@params`, `@request_object`).
    def call(context : HTTP::Server::Context)
      {% if @type.class? %}
        dup.serve(context)
      {% else %}
        serve(context)
      {% end %}
    end

    # :nodoc:
    protected def serve(context : HTTP::Server::Context)
      @context = context
      @params = nil
      check_contract = check_contract?(context.request)
      # A contract is checked before `call`, so its body is read now and a body that cannot be read is
      # refused at the same point as ever.
      @params = Params(Request).new(context.request) if check_contract
      @request_object = nil

      # Set endpoint name header for performance monitoring
      endpoint_name = self.class.name.split("::").last
      context.request.headers["X-Azu-Endpoint"] = endpoint_name

      RequestContext.scope(context) do |info|
        info.endpoint = endpoint_name
        begin
          enforce_contract if check_contract
          negotiate_format
        rescue ex : Azu::Response::Error
          ex.to_s(context)
          next
        end
        write_response(call, context)
      end
      context
    end

    # Whether the request is parsed and checked against its contract before `call`. A contract with no fields
    # and no rules has nothing to check, so only a body that names its format is still read (a malformed one is
    # a 400). A contract that inherits its rules defines no constants of its own and is always checked.
    private def check_contract?(request : HTTP::Request) : Bool
      {% if Request.stringify == "Azu::Request" %}
        false
      {% elsif Request.resolve.instance_vars.empty? && Request.resolve.has_constant?("SCHEMA_VALIDATORS") && Request.resolve.has_constant?("SCHEMA_VALIDATIONS") &&
                 Request.resolve.constant("SCHEMA_VALIDATORS").empty? && Request.resolve.constant("SCHEMA_VALIDATIONS").empty? %}
        Params::Body.format?(request)
      {% else %}
        true
      {% end %}
    end

    # Refuses a request the response type cannot be rendered for before `call` runs (406), when the
    # type is known to be `Response::Negotiable`. For a union of them, the formats all members render;
    # a union with a member that is not negotiable is only checked when the response is written.
    private def negotiate_format : Nil
      {% begin %}
        {% types = Response.resolve.union? ? Response.resolve.union_types : [Response.resolve] %}
        {% if types.all? { |type| type <= Azu::Response::Negotiable } %}
          {% if types.size == 1 %}
            formats = Response.formats
          {% else %}
            formats = {{ types[0] }}.formats
            {% for type in types[1..-1] %}
              formats &= {{ type }}.formats
            {% end %}
          {% end %}
          Negotiation.negotiate!(formats, context.request) unless formats.empty?
        {% end %}
      {% end %}
    end

    private def write_response(result, context : HTTP::Server::Context) : Nil
      if result.is_a?(Azu::Response)
        result.write_to(context)
      else
        context.response << result.render
      end
    end

    macro included
      @@resource : String = ""

      # The `{verb, path}` pairs the verb macros declared on this type, in order. They are registered on
      # `Azu::App.default` on first use; `Router::Builder#endpoint` registers them on any other app.
      # Kept per type (keyed by its name), so a subclass never sees its siblings' routes.
      def self.routes : Array(Tuple(String, String))
        Azu::DeclaredEndpoints.routes_of(name)
      end

      def self.path(**params)
        url = Azu.mounted_path(self, @@resource)
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
        routes << { {{method}}, path }
        Azu::DeclaredEndpoints.declare(->(router : Azu::Router) { router.{{method.id}}(path, new); nil })

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

      {% request_name = Request.stringify.split("::").last.underscore.downcase.id %}

      # A request that breaks its contract never reaches `call`: it is answered with a 422 listing
      # the failing fields (and a 400 when the body cannot be parsed at all), rendered by the endpoint
      # itself so that it holds without a `Rescuer` in the handler stack. An endpoint declared
      # with the bare `Azu::Request` module has no contract to enforce.
      private def enforce_contract : Nil
        {% unless Request.stringify == "Azu::Request" %}
          errors = contract.errors
          return if errors.empty?

          fields = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
          errors.each { |error| fields[error.field.to_s] << error.message }
          raise Azu::Response::ValidationError.new(fields.to_h)
        {% end %}
      end

      def {{request_name}} : Request
        contract
      end

      def {{request_name}}_contract : Request
        contract
      end
    end

    # Sets the content type for a response
    private def content_type(type : String)
      context.response.content_type = type
    end

    # The request contract, parsed once per call.
    private def contract : Request
      @request_object ||= params.typed_request
    end

    # Gets requests parameters, parsed on first use: an endpoint declared with the bare `Azu::Request`
    # that never reads them does not pay for parsing the query string and the body.
    # Raises if called before the endpoint is invoked via call(context)
    private def params : Params
      @params ||= Params(Request).new(context.request)
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
