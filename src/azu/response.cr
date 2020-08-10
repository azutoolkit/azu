module Azu
  module Response
    macro included
      @context = uninitialized HTTP::Server::Context
      forward_missing_to context
    end

    def header(key : String, value : String)
      headers[key] = value
    end

    def redirect(to location : String, status : Int32 = 301)
      status status
      header "Location", location
    end

    def status(code : Http::Status)
      status = code
    end

    def content_type(disposition : String)
      content_type = disposition
    end
  end
end