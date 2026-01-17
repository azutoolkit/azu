require "http"
require "../params"
require "./csrf"

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

      {% for method in Azu::Router::RESOURCES %}
      def self.{{method.id}}(path : Azu::Router::Path)
        @@resource = path
        Azu::CONFIG.router.{{method.id}} path, self.new
      end
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
