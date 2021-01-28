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

    @context : HTTP::Server::Context? = nil
    @parmas : Params? = nil
    @request_object : Request? = nil

    abstract def call : Response

    # :nodoc:
    def call(context : HTTP::Server::Context)
      @context = context
      @params = Params.new(@context.not_nil!.request)
      request_object(@context.not_nil!, @params.not_nil!)
      ContentNegotiator.content @context.not_nil!, call
    end

    private def request_object(context, params)
      @request_object = case context.request.content_type.sub_type
                        when "json" then Request.from_json(context.request.body.not_nil!)
                        else             Request.new(params)
                        end
    rescue ex : ArgumentError
      raise Response::Error.from_exception ex, 400
    end

    macro included
      {% request_name = Request.stringify.split("::").last.underscore.downcase.id %}

      def {{request_name}} : Request
        @request_object.not_nil!
      end
    end

    private def params : Params
      @params.not_nil!
    end

    private def context : HTTP::Server::Context
      @context.not_nil!
    end

    private def method
      Method.parse(context.request.method)
    end

    private def header
      context.request.headers
    end

    private def json
      JSON.parse(body.to_s)
    end

    private def cookies
      context.request.cookies
    end

    private def header(key : String, value : String)
      context.response.headers[key] = value
    end

    private def redirect(to location : String, status : Int32 = 301)
      status status
      header "Location", location
    end

    private def cookies(cookie : HTTP::Cookie)
      context.response.cookies << cookie
    end

    private def status(status : Int32)
      context.response.status_code = status
    end

    private def error(detail : String, status : Int32 = 400, errors = [] of String)
      Response::Error.new(detail, HTTP::Status.new(status), errors)
    end
  end
end
