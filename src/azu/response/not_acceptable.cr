module Azu::Response
  # The client accepts none of the representations a response can render (406). The body lists the
  # media types that can be rendered, as `application/problem+json` unless the app asks for the legacy
  # error format.
  class NotAcceptable < Error
    getter supported : Array(String)

    def initialize(@supported : Array(String), context : ErrorContext? = nil)
      super(
        title: "Not Acceptable",
        status: HTTP::Status::NOT_ACCEPTABLE,
        errors: [] of String,
        context: context
      )
      @detail = "None of the media types in the Accept header can be rendered. Supported: #{supported.join(", ")}."
    end

    # Answers in JSON whatever the client accepts: it just said it accepts nothing we render.
    def to_s(context : HTTP::Server::Context)
      Negotiation.vary(context.response)
      context.response.status_code = status_code
      context.response.content_type = json_content_type
      context.response.print json
    end

    def json : String
      {type: "about:blank", title: title, status: status_code, detail: detail, supported: supported}.to_json
    end

    def json_content_type : String
      Azu.current_config.error_format.legacy? ? super : "application/problem+json"
    end
  end
end
