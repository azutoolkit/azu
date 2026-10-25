module Azu::Response
  # The client accepts none of the representations a response can render (406). The body lists the
  # media types that can be rendered, as a problem document (`application/problem+json` for a client that
  # names it in Accept, `application/json` otherwise or with the legacy error format).
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
      context.response.content_type = json_content_type(Error.accepts_problem?(context))
      @instance ||= context.request.path
      context.response.print json
    end

    def json : String
      problem = {type: "about:blank", title: title, status: status_code, detail: detail, supported: supported}
      (path = instance) ? problem.merge(instance: path).to_json : problem.to_json
    end
  end
end
