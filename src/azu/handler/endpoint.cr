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
  #   struct PurgeQueueEndpoint
  #     include Azu::Endpoint(PurgeRequest, PurgeResponse)
  #
  #     post "/queues/:name/purge"
  #     summary "Purge all jobs from a queue"
  #     require_role :operator
  #     require_permissions "queues:purge"
  #     audit! critical: true
  #
  #     before_action :verify_unlocked
  #
  #     def call : PurgeResponse
  #       PurgeResponse.new
  #     end
  #   end
  # end
  # ```
  module Endpoint(Request, Response)
    include Routable

    # Internal control-flow exception raised by `halt!` to stop endpoint execution immediately.
    class Halt < Exception
    end

    CONTAINER_NAMESPACES = {"Api", "Endpoints", "Controllers", "Handlers", "Web"}

    # Derives a conventional dot-separated action name from an endpoint type name
    # (e.g., `"Api::Queues::PurgeEndpoint"` -> `"queues.purge"`, `"SignInEndpoint"` -> `"sign_in"`).
    def self.derive_action_name(type_name : String) : String
      parts = type_name.split("::").reject(&.empty?)
      while parts.size > 1 && CONTAINER_NAMESPACES.includes?(parts.first)
        parts.shift
      end
      return "endpoint" if parts.empty?

      last = parts.last
      {"Endpoint", "Handler", "Action"}.each do |suffix|
        if last.ends_with?(suffix) && last.size > suffix.size
          last = last[0, last.size - suffix.size]
          break
        end
      end
      parts[-1] = last
      parts.map(&.underscore).join(".")
    end

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

    # Route metadata and access options declared on this endpoint's type.
    def route_options : RouteOptions
      self.class.route_options
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
      @request_object = nil

      # Set endpoint name header for performance monitoring. A literal on purpose: the macro expands per
      # receiver type, so a subclass names itself and nothing is split or allocated per request.
      endpoint_name = {{ @type.name.stringify.split("::").last }}
      context.request.headers["X-Azu-Endpoint"] = endpoint_name

      begin
        RequestContext.scope(context) do |info|
          info.endpoint = endpoint_name
          begin
            if check_contract
              # Read the body now, as the check needs it: one that cannot be read (400, 413) is refused before `call`.
              @params = Params(Request).new(context.request)
              enforce_contract
            end
            negotiate_format
            execute_action(context)
          rescue Halt
            next
          rescue ex : Azu::Response::Error
            context.azu_last_error = ex
            ex.to_s(context)
            next
          end
        end
      ensure
        # Uploaded files live as long as the request: copy one you want to keep (see "Handle file uploads").
        @params.try(&.cleanup_files)
      end
      context
    end

    # Registers one or more methods on this endpoint to run before `#call`.
    macro before_action(*names)
      {% for name in names %}
        {% BEFORE_ACTIONS << {@type.name.stringify, name.id.stringify} %}
      {% end %}
    end

    # Registers one or more methods on this endpoint to run after `#call` (taking 0 args or `(response)`).
    macro after_action(*names)
      {% for name in names %}
        {% AFTER_ACTIONS << {@type.name.stringify, name.id.stringify} %}
      {% end %}
    end

    # Registers one or more methods on this endpoint to wrap `before_action`, `#call`, and `after_action` via `yield`.
    macro around_action(*names)
      {% for name in names %}
        {% AROUND_ACTIONS << {@type.name.stringify, name.id.stringify} %}
      {% end %}
    end

    # Runs `around_action`, `before_action`, `#call`, `after_action`, and writes the response.
    # Expanded at compile time for `@type` with zero per-request heap allocation.
    private def execute_action(context : HTTP::Server::Context) : Nil
      {% begin %}
        {% lineage = [@type.name.stringify] + @type.ancestors.map(&.name.stringify) %}
        {% around_pairs = (@type.class? && @type.superclass && @type.superclass.has_constant?("AROUND_ACTIONS")) ? @type.superclass.constant("AROUND_ACTIONS") : @type.constant("AROUND_ACTIONS") %}
        {% before_pairs = (@type.class? && @type.superclass && @type.superclass.has_constant?("BEFORE_ACTIONS")) ? @type.superclass.constant("BEFORE_ACTIONS") : @type.constant("BEFORE_ACTIONS") %}
        {% after_pairs = (@type.class? && @type.superclass && @type.superclass.has_constant?("AFTER_ACTIONS")) ? @type.superclass.constant("AFTER_ACTIONS") : @type.constant("AFTER_ACTIONS") %}
        {% arounds = around_pairs.select { |pair| lineage.includes?(pair[0]) }.map { |pair| pair[1] } %}
        {% befores = before_pairs.select { |pair| lineage.includes?(pair[0]) }.map { |pair| pair[1] } %}
        {% afters = after_pairs.select { |pair| lineage.includes?(pair[0]) }.map { |pair| pair[1] } %}
        {% if arounds.empty? && befores.empty? && afters.empty? %}
          write_response(call, context)
        {% else %}
          {% code = "" %}
          {% for action in befores %}
            {% code = "#{code.id}#{action.id}\n" %}
          {% end %}
          {% code = "#{code.id}action_result = call\n" %}
          {% for action in afters %}
            {% method_def = @type.methods.find { |method_node| method_node.name == action.id.stringify } %}
            {% if method_def && method_def.args.size > 0 %}
              {% code = "#{code.id}#{action.id}(action_result)\n" %}
            {% else %}
              {% code = "#{code.id}#{action.id}\n" %}
            {% end %}
          {% end %}
          {% code = "#{code.id}result = action_result\n" %}
          {% for idx in (0...arounds.size) %}
            {% action = arounds[arounds.size - 1 - idx] %}
            {% code = "#{action.id} do\n#{code.id}end\n" %}
          {% end %}
          result : Response? = nil
          {{ code.id }}
          if final_result = result
            write_response(final_result, context)
          end
        {% end %}
      {% end %}
    end

    # Whether the request is parsed and checked against its contract before `call`. A contract that defines
    # nothing beyond a bare `include Azu::Request` (no fields, no rules, no methods of its own) has nothing to
    # check, so only a body that names its format is still read (a malformed one is a 400). Any method of its own
    # may refuse a request (`errors`, a constructor such as `from_www_form` or `initialize`), so it is checked, and
    # so is a contract that inherits its rules: it defines no constants of its own. Rules add constants, not
    # methods. Methods are compared as source: the generated ones name no type, so a bare contract matches
    # `BareRequest`, and one that did would only turn the skip off.
    private def check_contract?(request : HTTP::Request) : Bool
      {% begin %}
        {% contract = Request.resolve %}
        {% bare = ::Azu::BareRequest %}
        {% if Request.stringify == "Azu::Request" %}
          false
        {% elsif contract.instance_vars.empty? &&
                   %w(SCHEMA_VALIDATORS SCHEMA_VALIDATIONS).all? { |rules| contract.has_constant?(rules) && contract.constant(rules).empty? } &&
                   contract.methods.map(&.stringify).sort == bare.methods.map(&.stringify).sort &&
                   contract.class.methods.map(&.stringify).sort == bare.class.methods.map(&.stringify).sort %}
          Params::Body.format?(request)
        {% else %}
          true
        {% end %}
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

      BEFORE_ACTIONS = [] of Tuple(String, String)
      AFTER_ACTIONS  = [] of Tuple(String, String)
      AROUND_ACTIONS = [] of Tuple(String, String)

      # Route metadata and access requirements declared on this endpoint (including any inherited from a superclass).
      def self.route_options : Azu::RouteOptions
        own = Azu::DeclaredEndpoints.class_route_options(name)
        \{% if @type.superclass && !["Reference", "Value", "Struct", "Object"].includes?(@type.superclass.name.stringify) %}
          \{{ @type.superclass }}.route_options.merge(own)
        \{% else %}
          own
        \{% end %}
      end

      def self.route_options=(options : Azu::RouteOptions) : Azu::RouteOptions
        Azu::DeclaredEndpoints.set_class_route_options(name, options)
      end

      private def self.own_route_options : Azu::RouteOptions
        Azu::DeclaredEndpoints.class_route_options(name)
      end

      # Conventional dot-separated action name derived from this endpoint's type name
      # (e.g. `Queues::PurgeEndpoint` -> `"queues.purge"`).
      def self.conventional_action_name : String
        Azu::Endpoint.derive_action_name(name)
      end

      # Marks this endpoint as `public: true` (authentication and authorization are skipped).
      def self.public!(flag : Bool = true) : Nil
        opts = own_route_options
        self.route_options = opts.copy_with(public: flag, requires: flag ? nil : opts.requires)
      end

      # Requires the authenticated principal to hold at least `role` (or any of `roles`, or higher in `c.auth.roles`).
      def self.require_role(*roles : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.role(*roles))
      end

      # Alias for `require_role` when listing one or more allowed roles.
      def self.allow_roles(*roles : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.role(*roles))
      end

      # Requires the authenticated principal to hold all listed `permissions`.
      def self.require_permissions(*permissions : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.permissions(*permissions))
      end

      # Requires the authenticated principal to hold at least one of the listed `permissions`.
      def self.require_any_permission(*permissions : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.any_permission(*permissions))
      end

      # OAuth 2.0 alias for `require_permissions`: requires all listed scopes.
      def self.require_scopes(*scopes : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.scopes(*scopes))
      end

      # OAuth 2.0 alias for `require_any_permission`: requires at least one of the listed scopes.
      def self.require_any_scope(*scopes : Symbol | String) : Nil
        self.route_options = own_route_options.with_requirement(Azu::Access.any_scope(*scopes))
      end

      # Combines an explicit `Azu::Access::Requirement` into this endpoint's route options.
      def self.requires(requirement : Azu::Access::Requirement) : Nil
        self.route_options = own_route_options.with_requirement(requirement)
      end

      # Exempts this endpoint from the enrolment gate (`principal.enrolment_pending?` / `c.auth.enrolment_gate`).
      def self.enrolment_exempt!(exempt : Bool = true) : Nil
        self.route_options = own_route_options.copy_with(enrolment_exempt: exempt)
      end

      # Exempts this endpoint from CSRF validation (`Handler::CSRF`).
      def self.csrf_exempt!(exempt : Bool = true) : Nil
        self.route_options = own_route_options.copy_with(csrf_exempt: exempt)
      end

      # Configures audit logging for this endpoint.
      def self.audit(action : String? = nil, *, critical : Bool = false, enabled : Bool = true) : Nil
        opts = own_route_options
        self.route_options = opts.copy_with(
          audit: enabled,
          audit_action: action || opts.audit_action,
          audit_critical: critical
        )
      end

      # Enables audit logging for this endpoint and automatically derives `audit_action` from
      # `conventional_action_name` unless an explicit `audit_action` was already set.
      def self.audit!(*, critical : Bool = false) : Nil
        opts = own_route_options
        self.route_options = opts.copy_with(
          audit: true,
          audit_action: opts.audit_action || conventional_action_name,
          audit_critical: critical
        )
      end

      # Disables audit logging for this endpoint (`audit: false`).
      def self.no_audit! : Nil
        self.route_options = own_route_options.copy_with(audit: false)
      end

      # Sets the OpenAPI summary for this endpoint.
      def self.summary(text : String) : Nil
        self.route_options = own_route_options.copy_with(summary: text)
      end

      # Sets the OpenAPI description for this endpoint.
      def self.description(text : String) : Nil
        self.route_options = own_route_options.copy_with(description: text)
      end

      # Sets the maximum request body size in bytes (`413 Payload Too Large` when exceeded) for this endpoint.
      def self.max_body_size(bytes : Int) : Nil
        self.route_options = own_route_options.copy_with(max_body_size: bytes.to_u64)
      end

      # Sets the allowed request `Content-Type` media types (`415 Unsupported Media Type` when violated) for this endpoint.
      def self.content_types(*types : String) : Nil
        self.route_options = own_route_options.copy_with(content_types: types.to_a)
      end

      # Sets the allowed request `Content-Type` media types (`415 Unsupported Media Type` when violated) for this endpoint.
      def self.content_types(types : Array(String)) : Nil
        self.route_options = own_route_options.copy_with(content_types: types)
      end

      # Declares the status this endpoint answers on success, for the OpenAPI document (`204` documents no content).
      # The endpoint still sets it at run time with `status`; this only tells the generator.
      def self.success_status(code : Int) : Nil
        self.route_options = own_route_options.copy_with(success_status: code.to_i)
      end

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

      # :nodoc:
      def self._declare_default_route(verb : String, path : Azu::Router::Path, inline_opts : Azu::RouteOptions) : Nil
        \{% begin %}
          \{% inits = @type.methods.select { |m| m.name == "initialize" } %}
          \{% can_default_new = inits.empty? || inits.any? { |m| m.args.all? { |a| !a.default_value.is_a?(Nop) } } %}
          \{% if can_default_new %}
            Azu::DeclaredEndpoints.declare(
              ->(router : Azu::Router) {
                router.register(verb, path, new, inline_opts)
                nil
              },
              "#{verb.upcase} #{path}"
            )
          \{% end %}
        \{% end %}
      end

      # Calculate resource name for helper generation
      {%
        helper_resource_name = @type.stringify.split("::")
        helper_resource_name = helper_resource_name.size > 1 ? helper_resource_name[-2..-1].join("_") : helper_resource_name.last
        helper_resource_name = helper_resource_name.underscore.gsub(/\_endpoint/, "").id
      %}

      {% for method in Azu::Router::RESOURCES %}
      def self.{{method.id}}(path : Azu::Router::Path, options : Azu::RouteOptions? = nil, **opts)
        inline_opts = options || Azu::RouteOptions.new(**opts)
        Azu::DeclaredEndpoints.set_route_options(name, {{method}}, path, inline_opts)
        _declare_default_route({{method}}, path, inline_opts)
        @@resource = path
        routes << { {{method}}, path }

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
          csrf_field = Azu::Helpers::Util.csrf_input(env)
          Crinja::SafeString.new(%(<form action="#{HTML.escape(path)}" method="post"#{attrs}>#{csrf_field}#{method_field}#{hidden_fields}))
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
          confirm_attr = confirm_val.none? ? "" : %( onclick="return confirm('#{HTML.escape(Azu::Helpers::Util.js_string_escape(confirm_val.to_s))}')")

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

          csrf_field = Azu::Helpers::Util.csrf_input(env)
          Crinja::SafeString.new(<<-HTML
          <form action="#{HTML.escape(path)}" method="post" style="display:inline">#{csrf_field}<input type="hidden" name="_method" value="delete">#{hidden_fields}<button type="submit"#{class_attr}#{confirm_attr}>#{HTML.escape(text)}</button></form>
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
      # Registered with the helper registry, which every app's templates apply, so a non-default app's templates
      # have it too; persistent, so `Registry.reset!` (a spec's clean slate) cannot drop an endpoint's filter.
      Azu::Helpers::Registry.register_filter(
        :{{resource_name}}_path,
        Crinja.filter({id: nil}) do
          {{@type.name.id}}.path(id: arguments["id"])
        end,
        persistent: true)

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

    # Authenticated principal helpers
    private def principal : Auth::Principal?
      context.principal?
    end

    private def principal? : Auth::Principal?
      context.principal?
    end

    private def principal! : Auth::Principal
      if p = context.principal?
        p
      else
        auth = Azu.current_config.auth
        raise Azu::Response::AuthenticationError.new(
          auth.unauthorized_message,
          code: auth.unauthorized_code,
          www_authenticate: auth.www_authenticate
        )
      end
    end

    private def current_user : Auth::Principal?
      context.principal?
    end

    private def current_user? : Auth::Principal?
      context.principal?
    end

    private def current_user! : Auth::Principal
      principal!
    end

    # True when a principal is authenticated on the current request.
    private def authenticated? : Bool
      !context.principal?.nil?
    end

    # True when the authenticated principal satisfies `role` (including role hierarchy inheritance).
    private def role?(role_name : Symbol | String) : Bool
      user = context.principal?
      return false unless user
      Access.role(role_name).satisfied_by?(user, Azu.current_config.auth.roles)
    end

    # True when the authenticated principal holds `perm`.
    private def permission?(perm : Symbol | String) : Bool
      context.principal?.try(&.has_permission?(perm)) || false
    end

    # OAuth 2.0 alias for `permission?`: true when the authenticated principal holds `scope_name`.
    private def scope?(scope_name : Symbol | String) : Bool
      permission?(scope_name)
    end

    # Verified token claims hash for the current principal (empty hash when unauthenticated).
    private def claims : Hash(String, JSON::Any)
      context.principal?.try(&.claims) || ({} of String => JSON::Any)
    end

    # Returns `context.authly_claims` when `Authly` is loaded, or `principal?.try(&.claims)`.
    private def authly_claims
      {% if @top_level.has_constant?("Authly") %}
        context.authly_claims
      {% else %}
        context.principal?.try(&.claims)
      {% end %}
    end

    # Returns `context.authly_claims!` when `Authly` is loaded, or `principal!.claims`.
    private def authly_claims!
      {% if @top_level.has_constant?("Authly") %}
        context.authly_claims!
      {% else %}
        principal!.claims
      {% end %}
    end

    # Imperative in-action authorization check against the current `principal!`.
    private def authorize!(requirement : Access::Requirement, *, message : String? = nil, code : String? = nil) : Auth::Principal
      user = principal!
      auth = Azu.current_config.auth
      unless requirement.satisfied_by?(user, auth.roles)
        raise Azu::Response::AuthorizationError.new(
          message || auth.forbidden_message,
          code: code || auth.forbidden_code
        )
      end
      user
    end

    # Imperative in-action authorization check using role/permission/scope keyword arguments.
    private def authorize!(
      *,
      role : Symbol | String | Nil = nil,
      roles : Enumerable? = nil,
      permissions : Enumerable? = nil,
      any_permission : Enumerable? = nil,
      scopes : Enumerable? = nil,
      any_scope : Enumerable? = nil,
      message : String? = nil,
      code : String? = nil,
    ) : Auth::Principal
      opts = RouteOptions.new(
        role: role,
        roles: roles,
        permissions: permissions,
        any_permission: any_permission,
        scopes: scopes,
        any_scope: any_scope
      )
      if req = opts.requires
        authorize!(req, message: message, code: code)
      else
        principal!
      end
    end

    # Raises `401 Unauthorized` (`Response::AuthenticationError`).
    private def unauthorized!(
      message : String = Azu.current_config.auth.unauthorized_message,
      *,
      code : String = Azu.current_config.auth.unauthorized_code,
      www_authenticate : String? = Azu.current_config.auth.www_authenticate,
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::AuthenticationError.new(message, code: code, www_authenticate: www_authenticate, details: details)
    end

    # Raises `403 Forbidden` (`Response::AuthorizationError`).
    private def forbidden!(
      message : String = Azu.current_config.auth.forbidden_message,
      *,
      code : String = Azu.current_config.auth.forbidden_code,
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::AuthorizationError.new(message, code: code, details: details)
    end

    # Raises `404 Not Found` (`Response::NotFound`).
    private def not_found!(
      message : String = "The server can't find the requested resource.",
      *,
      path : String = context.request.path,
      code : String = "not_found",
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::NotFound.new(path, message: message, code: code, details: details)
    end

    # Raises `400 Bad Request` (`Response::BadRequest`).
    private def bad_request!(
      message : String = "The server cannot or will not process the request due to something that is perceived to be a client error.",
      *,
      code : String = "bad_request",
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::BadRequest.new(message, code: code, details: details)
    end

    # Raises `409 Conflict` (`Response::Conflict`).
    private def conflict!(
      message : String = "The request could not be completed due to a conflict with the current state of the target resource.",
      *,
      code : String = "conflict",
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::Conflict.new(message, code: code, details: details)
    end

    # Raises `422 Unprocessable Entity` (`Response::ValidationError`) for a specific field.
    private def unprocessable!(
      field : String,
      message : String,
      *,
      code : String = "validation_failed",
    ) : NoReturn
      raise Azu::Response::ValidationError.new(field, message, code: code)
    end

    # Raises `422 Unprocessable Entity` (`Response::ValidationError`) with a message.
    private def unprocessable!(
      message : String,
      *,
      code : String = "validation_failed",
      details : JSON::Any? = nil,
    ) : NoReturn
      raise Azu::Response::ValidationError.new(message, code: code, details: details)
    end

    # Immediately halts endpoint execution and writes `status` and `body` to `context.response`.
    private def halt!(
      status : HTTP::Status | Int32 = 200,
      body : String = "",
      headers : HTTP::Headers? = nil,
    ) : NoReturn
      if status.is_a?(HTTP::Status)
        context.response.status = status
      else
        context.response.status_code = status
      end
      headers.try do |hdrs|
        hdrs.each { |k, v| context.response.headers[k] = v }
      end
      context.response.print(body) unless body.empty?
      raise Halt.new
    end
  end
end
