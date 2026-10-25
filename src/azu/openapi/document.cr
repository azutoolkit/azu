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
      @legacy = @app.config.error_format.legacy?.as(Bool)
    end

    def build : Document
      collect(@app.router)

      root = Map{"openapi" => "3.1.0", "info" => info_object, "paths" => @paths}
      root["servers"] = @servers.map { |server| server_object(server).as(Value) } unless @servers.empty?
      components = components_object
      root["components"] = components unless components.empty?
      Document.new(root)
    end

    private def collect(router : Router) : Nil
      routes = router.registered_routes
      routes.each do |route|
        endpoint = route.endpoint
        if endpoint.is_a?(Router::Mount)
          collect_mount(endpoint, route)
        elsif !route.method.web_socket? && !route.method.connect? && !implied_by_get?(route, routes)
          add_route(route, router.mount_prefix, endpoint)
        end
      end
    end

    # A mount registers itself for every method and for its sub paths; its child is visited once.
    private def collect_mount(mount : Router::Mount, route : Router::Route) : Nil
      return if route.path.ends_with?("/*mount_path")
      collect(mount.child.router) if @mounts_seen.add?(mount.object_id)
    end

    # Registering a GET also registers HEAD and OPTIONS for the same endpoint.
    private def implied_by_get?(route : Router::Route, routes : Array(Router::Route)) : Bool
      return false unless route.method.head? || route.method.options?
      routes.any? { |other| other.method.get? && other.path == route.path && other.endpoint == route.endpoint }
    end

    private def add_route(route : Router::Route, prefix : String, endpoint : Routable) : Nil
      return unless operation = endpoint.openapi_operation

      path = canonical(template(full_path(prefix, route.path)))
      item = (@paths[path] ||= Map.new).as(Map)
      item[route.method.to_s.downcase] = operation_object(route.method, path, operation)
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

    private def operation_object(method : Method, path : String, operation : Operation) : Map
      names = path_parameter_names(path)
      object = Map{"operationId" => unique_id(operation.operation_id)}
      object["tags"] = operation.tags.map(&.as(Value)) unless operation.tags.empty?

      parameters = names.map { |name| path_parameter(name, operation.form_schema).as(Value) }
      add_request(object, parameters, method, names, operation)
      object["parameters"] = parameters unless parameters.empty?
      object["responses"] = responses(operation, !operation.request_schema.nil?, !names.empty?)
      object
    end

    # Query parameters for a method without a body. For the others Azu reads a JSON body, or a form
    # into which the path and the query string are merged: the JSON body must carry the path-named
    # fields itself, the form need not.
    private def add_request(object : Map, parameters : Array(Value), method : Method, names : Array(String), operation : Operation) : Nil
      return unless json = operation.request_schema
      return unless form = operation.form_schema

      form = without(form, names)
      if NO_BODY.includes?(method)
        parameters.concat query_parameters(form)
      elsif body = request_body(json, form)
        object["requestBody"] = body
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

    private def request_body(json : Map, form : Map) : Map?
      return if json["properties"].as(Map).empty?
      Map{
        "required" => json.has_key?("required"),
        "content"  => Map{
          "application/json"                  => Map{"schema" => json},
          "application/x-www-form-urlencoded" => Map{"schema" => form},
        },
      }
    end

    private def responses(operation : Operation, contract : Bool, path_parameters : Bool) : Map
      responses = Map{"200" => success(operation)}
      if contract
        responses["400"] = problem(Problems::BAD_REQUEST)
        responses["422"] = problem(Problems::VALIDATION_FAILED)
      end
      responses["404"] = problem(Problems::NOT_FOUND) if path_parameters
      responses
    end

    # A `Negotiable` response lists every media type it renders; the JSON one carries the schema.
    private def success(operation : Operation) : Map
      response = Map{"description" => "Successful response"}
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
      @problems.each do |name|
        schema = name == Problems::VALIDATION_FAILED ? Problems.validation_schema(@legacy) : Problems.error_schema(@legacy)
        schemas[schema] = all_problems[schema]
      end
      components["schemas"] = schemas unless schemas.empty?
      unless @problems.empty?
        shared = Problems.responses(@legacy)
        components["responses"] = @problems.each_with_object(Map.new) { |name, responses| responses[name] = shared[name] }
      end
      components
    end
  end
end
