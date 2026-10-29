module Azu::Response
  # JSON::Builder#end_document validates the document and then calls #flush.
  # The HTTP server owns the flush: doing it here forces even tiny bodies into
  # chunked transfer and separates the final chunk from the response data.
  private class JsonOutput < IO
    def initialize(@response : HTTP::Server::Response)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("JSON response output is write-only")
    end

    def write(slice : Bytes) : Nil
      @response.write(slice)
    end

    def flush : Nil
    end
  end

  # Opt-in JSON serialization directly to the HTTP response's buffered IO. The
  # value can be a NamedTuple, a JSON::Serializable model, or any type implementing
  # `to_json(JSON::Builder)`. No intermediate Hash or complete body String is needed.
  #
  # ```
  # Azu::Response::Json.new({message: "Hello, World!"})
  # ```
  #
  # Set status and headers before returning this response. Large bodies can commit
  # headers during serialization: serializer failures cannot then become an error
  # page. Keep a buffered `render` response when all-or-nothing serialization matters.
  # HTTP framing, compression and HEAD suppression remain owned by the server.
  struct Json(T)
    include Azu::Response

    getter value : T

    def initialize(@value : T)
    end

    # Compatibility for callers that explicitly need a String (allocates the body).
    def render : String
      @value.to_json
    end

    def write_to(context : HTTP::Server::Context) : Nil
      context.response.content_type = "application/json"
      @value.to_json(JsonOutput.new(context.response))
    end
  end
end
