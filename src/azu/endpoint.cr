require "./helpers"

module Azu
  # Defines a Azu endpoint.
  # The endpoint is the final stage of the request process
  # Each endpoint is the location from which APIs can access the resources of your application
  # to carry out their function.
  #
  # Azu endpoints is a simple module that defines the request and response object
  # to execute your application business domain logic. Endpoints specify where resources can be
  # accessed by APIs and the key role is to guarantee the correct functioning of the calls.
  #
  # ## Correctness
  #
  # To ensure correctness Azu Endpoints are design with the Request and Response pattern in mind
  # you can think of it as input and output to a function, where the request is the input and the
  # response is the output.
  #
  # Request and Response objects are type safe objects that can be designed by contract.
  # Read more about `Azu::Contract`
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
    include Helpers

    @context = uninitialized HTTP::Server::Context
    @params : Params? = nil
    
    abstract def call : Response

    # :nodoc:
    def call(context : HTTP::Server::Context)
      @context = context
      ContentNegotiator.content @context, call
    end

    def params 
      @params ||= Params.new(@context.request)
    end

    macro included
      {% request_name = Request.stringify.split("::").last.underscore.downcase.id %}
      @{{request_name}} : Request? = nil
      
      def {{request_name}} : Request
        @{{request_name}} ||= case @context.request.content_type.sub_type
        when "json" then JsonReq.from_json(@context.request.body.not_nil!)
        else JsonReq.new(params) end
      end
    end
  end
end
