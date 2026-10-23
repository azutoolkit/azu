require "http"
require "./csrf"

module Azu
  # Request/response helpers shared by `Azu::Endpoint` and the legacy `Azu::Action`.
  #
  # The including type must provide `context`.
  module EndpointHelpers
    # Sets the content type for a response
    private def content_type(type : String)
      context.response.content_type = type
    end

    # Gets the request http method
    private def method
      Method.parse(context.request.method)
    end

    # Gets the HTTP headers for a request
    private def header
      context.request.headers
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
