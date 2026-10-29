require "../../src/azu"

# The same source builds against the base and candidate revisions. Use
# -Dbench_direct_json only on the candidate to measure the opt-in IO serializer.
module HttpHotPath
  struct Request
    include Azu::Request
  end

  struct Text
    include Azu::Response

    def initialize(@body : String)
    end

    def render : String
      @body
    end
  end

  struct Plaintext
    include Azu::Endpoint(Request, Text)

    def call : Text
      content_type "text/plain"
      Text.new("Hello, World!")
    end
  end

  alias Message = NamedTuple(message: String)
  {% if flag?(:bench_direct_json) %}
    alias JsonResponse = Azu::Response::Json(Message)
  {% else %}
    alias JsonResponse = Text
  {% end %}

  struct JsonEndpoint
    include Azu::Endpoint(Request, JsonResponse)

    def call : JsonResponse
      content_type "application/json"
      value = {message: "Hello, World!"}
      {% if flag?(:bench_direct_json) %}
        JsonResponse.new(value)
      {% else %}
        JsonResponse.new(value.to_json)
      {% end %}
    end
  end
end

Log.setup(:none)
{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "1").to_i)
{% end %}
app = Azu::App.new
app.config.env = Azu::Environment::Production
app.config.host = "127.0.0.1"
app.config.port = ENV.fetch("PORT", "3099").to_i
app.routes do
  get "/plaintext", HttpHotPath::Plaintext
  get "/json", HttpHotPath::JsonEndpoint
end
# Retain request IDs, security headers, error handling, connection limits and
# shutdown tracking. Only request logging is disabled for reproducible timings.
app.start(app.default_handlers.reject(Azu::Handler::Logger))
