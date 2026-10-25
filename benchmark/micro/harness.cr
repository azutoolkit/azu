require "../../src/azu"

# Bytes allocated per request by Azu's default stack and by a hand-written handler, both driven through the
# RequestProcessor HTTP::Server builds per connection: the difference is Azu's cost. Types mirror benchmark/apps/azu.
module HotPath
  WARMUP_REQUESTS =  200
  WINDOW_REQUESTS = 2000
  WINDOWS         =    3
  BODY            = "Hello, World!"
  # Static builds paths under its dir per request: a cwd-relative dir would make bytes grow with the cwd's length.
  STATIC_DIR = "/azu-hot-path/public"

  enum Stack
    Azu
    Baseline
  end

  struct NoRequest
    include Azu::Request
  end

  struct Raw
    include Azu::Response

    def initialize(@body : String)
    end

    def render : String
      @body
    end
  end

  struct PlaintextEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "text/plain"
      Raw.new(BODY)
    end
  end

  class NullIO < IO
    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
    end
  end

  # Allocated bytes per request on `path`: the smallest of several windows, because stray
  # allocations (a timer, the scheduler) can only add to a window, never remove from it.
  def self.bytes_per_request(stack : Stack, path : String) : Float64
    processor = HTTP::Server::RequestProcessor.new(handler(stack))
    allocated_bytes(processor, path, WARMUP_REQUESTS)
    smallest = (1..WINDOWS).min_of { allocated_bytes(processor, path, WINDOW_REQUESTS) }
    smallest.to_f / WINDOW_REQUESTS
  end

  # The raw response to one request on `path`, so a stack that fails or 404s is caught instead of measured as cheap.
  def self.response(stack : Stack, path : String) : String
    String.build { |output| HTTP::Server::RequestProcessor.new(handler(stack)).process(requests(path, 1), output) }
  end

  # One keep-alive connection, as wrk's. The processor never yields (memory in, NullIO out), so nothing else runs in the
  # window; the fresh fiber starts, like a connection fiber, with no fiber-local state (RequestContext, Log context).
  private def self.allocated_bytes(processor : HTTP::Server::RequestProcessor, path : String, count : Int32) : UInt64
    input = requests(path, count)
    output = NullIO.new
    allocated = Channel(UInt64).new
    spawn do
      before = GC.stats.total_bytes
      processor.process(input, output)
      allocated.send GC.stats.total_bytes - before
    end
    allocated.receive
  end

  private def self.requests(path : String, count : Int32) : IO::Memory
    IO::Memory.new("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n" * count)
  end

  private def self.handler(stack : Stack) : HTTP::Handler | HTTP::Handler::HandlerProc
    case stack
    in .azu?      then azu_dispatcher
    in .baseline? then baseline
    end
  end

  private def self.azu_dispatcher : HTTP::Handler
    app = Azu::App.new
    app.config.env = Azu::Environment::Production
    app.routes do
      get "/plaintext", PlaintextEndpoint
      # They mirror the bench app's router size, which shapes the cost of finding /plaintext
      {% for i in 0...100 %}
        get "/api/v1/resource{{ i }}/:id", PlaintextEndpoint
      {% end %}
    end
    static = Azu::Handler::Static.new(STATIC_DIR, fallthrough: true, cache_max_age: app.config.assets.cache_max_age)
    handlers = app.default_handlers.reject(Azu::Handler::Logger)
    app.dispatcher(handlers.map! { |handler| handler.is_a?(Azu::Handler::Static) ? static : handler })
  end

  private def self.baseline : HTTP::Handler::HandlerProc
    ->(context : HTTP::Server::Context) do
      if context.request.path == "/plaintext"
        context.response.content_type = "text/plain"
        context.response.print BODY
      end
    end
  end
end
