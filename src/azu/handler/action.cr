require "http"
require "html"
require "../params"
require "./csrf"
require "./endpoint_helpers"
require "./endpoint_routing"
require "../helpers/registry"
require "../helpers/util"

module Azu
  # `Azu::Action(Request, Response)` is the typed, contract-first way to write an endpoint:
  # you declare the request and response types and `call` returns the response object.
  # It is the original `Azu::Endpoint(Request, Response)` module under its new name; new
  # code usually prefers the terser `Azu::Endpoint` class.
  #
  # In a Azu application, an endpoint is a simple testable object.
  #
  # This design provides self contained actions that don't share their context
  # accidentally with other actions. It also prevents gigantic controllers.
  # It has several advantages in terms of testability and control of an endpoint.
  #
  # ```
  # module ExampleApp
  #   class UserEndpoint
  #     include Azu::Action(UserRequest, UserResponse)
  #   end
  # end
  # ```
  #
  module Action(Request, Response)
    include HTTP::Handler
    include EndpointHelpers

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
      define_endpoint_routes

      {% request_name = Request.stringify.split("::").last.underscore.downcase.id %}

      def {{request_name}} : Request
        params.typed_request
      end

      def {{request_name}}_contract : Request
        params.typed_request
      end
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

    # Gets the request body as json when accepts equals to `application/json`
    private def json
      JSON.parse(params.json || "null")
    end
  end
end
