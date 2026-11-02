require "./operation"
require "./problems"

module Azu::OpenAPI
  record Info, title : String, version : String, description : String? = nil

  record Server, url : String, description : String? = nil

  # The OpenAPI 3.1 document of an app. It is a snapshot of the routes the app has when it is built.
  struct Document
    getter root : Map

    def initialize(@root : Map)
    end

    def to_h : Map
      @root
    end

    # The document as JSON with sorted keys, so the same app always yields the same bytes.
    def to_json(pretty : Bool = false) : String
      OpenAPI.encode(@root, pretty)
    end
  end

  # The OpenAPI document of `app`: every route that leads to an `Azu::Endpoint`, including the ones of
  # mounted apps below their mount path. Routes to hand written routables and WebSocket channels
  # have no contract to read and are left out.
  def self.document(app : App, info : Info, servers : Array(Server) = [] of Server) : Document
    Builder.new(app, info, servers).build
  end

  # :nodoc:
  class Builder
    NO_BODY = {Method::Get, Method::Delete, Method::Head, Method::Options, Method::Trace}

    def initialize(@app : App, @info : Info, @servers : Array(Server))
      @paths = Map.new
      @components = Components.new
      @operation_ids = Set(String).new
      @problems = Set(String).new
      @mounts_seen = Set(UInt64).new
      @templates = Hash(String, String).new
      @error_format = @app.config.error_format
      @has_secured_routes = false
    end

    def build : Document
      collect(@app.router, @app.config)

      root = Map{"openapi" => "3.1.0", "info" => info_object, "paths" => @paths}
      root["servers"] = @servers.map { |server| server_object(server).as(Value) } unless @servers.empty?
      components = components_object
      root["components"] = components unless components.empty?
      Document.new(root)
    end

    private def collect(router : Router, config : Configuration) : Nil
      routes = router.registered_routes
      routes.each do |route|
        endpoint = route.endpoint
        if endpoint.is_a?(Router::Mount)
          collect_mount(endpoint, route)
        elsif !route.method.web_socket? && !route.method.connect? && !implied_by_get?(route, routes)
          add_route(route, router.mount_prefix, endpoint, config)
        end
      end
    end

    # A mount registers itself for every method and for its sub paths; its child is visited once.
    private def collect_mount(mount : Router::Mount, route : Router::Route) : Nil
      return if route.path.ends_with?("/*mount_path")
      collect(mount.child.router, mount.child) if @mounts_seen.add?(mount.object_id)
    end

    # Registering a GET also registers HEAD for the same endpoint.
    private def implied_by_get?(route : Router::Route, routes : Array(Router::Route)) : Bool
      return false unless route.method.head?
      routes.any? { |other| other.method.get? && other.path == route.path && other.endpoint == route.endpoint }
    end

    private def add_route(route : Router::Route, prefix : String, endpoint : Routable, config : Configuration) : Nil
      return unless operation = endpoint.openapi_operation

      path = canonical(template(full_path(prefix, route.path)))
      item = (@paths[path] ||= Map.new).as(Map)
      item[route.method.to_s.downcase] = operation_object(route, path, operation, config)
      @components.merge(operation.components)
    end

    # `/users/:id` and `/files/*path` are `/users/{id}` and `/files/{path}`; a colon inside a segment
    # (`/users:search`) is literal.
    private def template(path : String) : String
      path.gsub(/\/[:*](\w+)/) { "/{#{$1}}" }
    end

    # Templates that differ only in the names of their parameters are one path in OpenAPI.
    private def canonical(path : String) : String
      @templates[path.gsub(/\{\w+\}/, "{}")] ||= path
    end

    private def full_path(prefix : String, path : String) : String
      return prefix.empty? ? path : prefix if path == "/"
      prefix + path
    end

    private def operation_object(route : Router::Route, path : String, operation : Operation, config : Configuration) : Map
      names = path_parameter_names(path)
      object = Map{"operationId" => unique_id(operation.operation_id)}
      route.summary.try { |summary| object["summary"] = summary }
      route.description.try { |description| object["description"] = description }
      object["tags"] = operation.tags.map(&.as(Value)) unless operation.tags.empty?

      parameters = names.map { |name| path_parameter(name, operation.form_schema).as(Value) }
      has_body = add_request(object, parameters, route, names, operation, config)
      object["parameters"] = parameters unless parameters.empty?

      req = route.effective_requirement(config.auth)
      secured = apply_security!(object, route, req, config)

      object["responses"] = responses(
        operation: operation,
        contract: !operation.request_schema.nil?,
        path_parameters: !names.empty?,
        secured: secured,
        route: route,
        has_body: has_body,
        config: config
      )
      object
    end

    private def auth_active?(config : Configuration) : Bool
      config.auth.enabled? ||
        !config.auth.authenticator.nil? ||
        config.router.has_before_hook?(Auth::Authorize) ||
        !config.auth.default_access.nil? ||
        !config.auth.verb_defaults.empty?
    end

    private def apply_security!(object : Map, route : Router::Route, req : Access::Requirement?, config : Configuration) : Bool
      if route.public?
        object["security"] = [] of Value if auth_active?(config)
        return false
      end

      return false unless req || auth_active?(config)

      @has_secured_routes = true
      scheme = config.auth.security_scheme_name
      scopes = [] of Value

      apply_requirement_metadata!(object, scopes, req, config) if req

      object["x-enrolment-exempt"] = true if route.enrolment_exempt?
      object["security"] = [Map{scheme => scopes}.as(Value)] of Value
      true
    end

    private def apply_requirement_metadata!(object : Map, scopes : Array(Value), requirement : Access::Requirement, config : Configuration) : Nil
      if role = requirement.role
        scopes << "role:#{role}"
        object["x-required-role"] = role
      end
      unless requirement.all_permissions.empty?
        requirement.all_permissions.each { |perm| scopes << perm }
        object["x-required-permissions"] = requirement.all_permissions.map(&.as(Value))
      end
      unless requirement.any_permissions.empty?
        requirement.any_permissions.each { |perm| scopes << perm }
        object["x-required-any-permissions"] = requirement.any_permissions.map(&.as(Value))
      end
      object["x-required-mfa"] = true if requirement.mfa?
      object["x-required-amr"] = requirement.amr.map(&.as(Value)) unless requirement.amr.empty?
      requirement.acr.try { |acr| object["x-required-acr"] = acr }
      object["x-required-social"] = true if requirement.social?
      object["x-required-social-providers"] = requirement.auth_providers.map(&.as(Value)) unless requirement.auth_providers.empty?
      return unless config.auth.document_requirements_in_description?

      note = "Requires #{requirement.summary}."
      existing = object["description"]?.try(&.as?(String))
      object["description"] = existing ? "#{existing} #{note}" : note
    end

    # Query parameters for a method without a body. For the others Azu reads a JSON body, or a form
    # into which the path and the query string are merged: the JSON body must carry the path-named
    # fields itself, the form need not.
    private def add_request(object : Map, parameters : Array(Value), route : Router::Route, names : Array(String), operation : Operation, config : Configuration) : Bool
      return false unless json = operation.request_schema
      return false unless form = operation.form_schema

      form = without(form, names)
      if NO_BODY.includes?(route.method)
        parameters.concat query_parameters(form)
        false
      elsif body = request_body(json, form, route, config)
        object["requestBody"] = body
        true
      else
        false
      end
    end

    private def path_parameter_names(path : String) : Array(String)
      path.scan(/\{(\w+)\}/).map(&.[1])
    end

    private def path_parameter(name : String, fields : Map?) : Map
      schema = fields.try { |object| object["properties"].as(Map)[name]? } || Map{"type" => "string"}
      Map{"name" => name, "in" => "path", "required" => true, "schema" => schema}
    end

    # The request object without the fields the path already carries.
    private def without(fields : Map, names : Array(String)) : Map
      properties = fields["properties"].as(Map).reject { |name, _| names.includes?(name) }
      required = (fields["required"]?.as?(Array(Value)) || [] of Value).reject { |name| names.includes?(name) }
      remaining = Map{"type" => "object", "properties" => properties}
      remaining["required"] = required unless required.empty?
      remaining
    end

    private def query_parameters(fields : Map) : Array(Value)
      required = fields["required"]?.as?(Array(Value)) || [] of Value
      fields["properties"].as(Map).map do |name, schema|
        Map{"name" => name, "in" => "query", "required" => required.includes?(name), "schema" => schema}.as(Value)
      end
    end

    private def request_body(json : Map, form : Map, route : Router::Route, config : Configuration) : Map?
      return if json["properties"].as(Map).empty?

      content = Map{
        "application/json"                  => Map{"schema" => json},
        "application/x-www-form-urlencoded" => Map{"schema" => form},
      }
      if route.content_types || config.hygiene.strict_content_type?
        allowed = (route.content_types || config.hygiene.allowed_content_types).map(&.downcase)
        content.reject! { |media_type, _| !allowed.includes?(media_type.downcase) }
        if content.empty?
          allowed.each { |media_type| content[media_type] = Map{"schema" => json} }
        end
      end

      Map{
        "required" => json.has_key?("required"),
        "content"  => content,
      }
    end

    private def responses(
      operation : Operation,
      contract : Bool,
      path_parameters : Bool,
      secured : Bool,
      route : Router::Route,
      has_body : Bool,
      config : Configuration,
    ) : Map
      responses = Map{success_code(route) => success(operation, route.success_status)}
      if contract
        responses["400"] = problem(Problems::BAD_REQUEST)
        responses["422"] = problem(Problems::VALIDATION_FAILED)
      end
      if secured
        responses["401"] = problem(Problems::UNAUTHORIZED)
        responses["403"] = problem(Problems::FORBIDDEN)
      end
      responses["404"] = problem(Problems::NOT_FOUND) if path_parameters
      responses["405"] = problem(Problems::METHOD_NOT_ALLOWED) if config.router.method_not_allowed?
      add_hygiene_responses!(responses, route, has_body, config)
      responses
    end

    private def add_hygiene_responses!(responses : Map, route : Router::Route, has_body : Bool, config : Configuration) : Nil
      return if !has_body && NO_BODY.includes?(route.method)
      responses["413"] = problem(Problems::PAYLOAD_TOO_LARGE) if route.max_body_size || config.hygiene.max_body_size
      responses["415"] = problem(Problems::UNSUPPORTED_MEDIA_TYPE) if route.content_types || config.hygiene.strict_content_type?
    end

    # A `Negotiable` response lists every media type it renders; the JSON one carries the schema.
    private def success_code(route : Router::Route) : String
      (route.success_status || 200).to_s
    end

    private def success(operation : Operation, status : Int32?) : Map
      response = Map{"description" => status == 204 ? "No content" : "Successful response"}
      return response if status == 204
      schema = operation.response_schema
      if operation.response_types.empty?
        response["content"] = Map{"application/json" => Map{"schema" => schema}} if schema
      else
        response["content"] = operation.response_types.each_with_object(Map.new) do |media_type, content|
          content[media_type] = Map{"schema" => media_type == "application/json" && schema ? schema : Map{"type" => "string"}}
        end
      end
      response
    end

    private def problem(name : String) : Map
      @problems << name
      Problems.reference(name)
    end

    private def unique_id(id : String) : String
      candidate = id
      suffix = 1
      until @operation_ids.add?(candidate)
        suffix += 1
        candidate = "#{id}#{suffix}"
      end
      candidate
    end

    private def info_object : Map
      info = Map{"title" => @info.title, "version" => @info.version}
      @info.description.try { |description| info["description"] = description }
      info
    end

    private def server_object(server : Server) : Map
      object = Map{"url" => server.url}
      server.description.try { |description| object["description"] = description }
      object
    end

    private def components_object : Map
      components = Map.new
      schemas = @components.schemas.dup
      all_problems = Problems.schemas
      all_problems[Problems::ENVELOPE] = Problems.envelope_schema(@app.config.error_envelope.wrapper_key)
      @problems.each do |name|
        schema = name == Problems::VALIDATION_FAILED ? Problems.validation_schema(@error_format) : Problems.error_schema(@error_format)
        schemas[schema] = all_problems[schema]
      end
      components["schemas"] = schemas unless schemas.empty?
      unless @problems.empty?
        shared = Problems.responses(@error_format)
        components["responses"] = @problems.each_with_object(Map.new) { |name, responses| responses[name] = shared[name] }
      end
      if @has_secured_routes
        scheme_obj = Map{"type" => "http", "scheme" => "bearer"}
        if fmt = @app.config.auth.bearer_format
          scheme_obj["bearerFormat"] = fmt
        end
        components["securitySchemes"] = Map{@app.config.auth.security_scheme_name => scheme_obj}
      end
      components
    end
  end
end
