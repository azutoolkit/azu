require "../../src/azu"

# Bytes allocated per request by three stacks, each driven through the RequestProcessor HTTP::Server builds per
# connection: the default Azu stack, azu-min (router, endpoint and Rescuer) and a hand-written baseline handler. The
# difference over the baseline is the framework's cost. `bytes_per_call` measures a block the same way, for component
# checks. The routes mirror benchmark/apps/azu, except that one resource endpoint serves all 100 routes with a
# simplified body (`{"route":"resource","id":...}`, the bench app has a struct per route); that does not change the
# difference over the baseline.
module HotPath
  WARMUP_REQUESTS =  200
  WINDOW_REQUESTS = 2000
  WINDOWS         =    3
  # More than the router's path cache holds (1000 entries), so the measured routing requests mostly miss it.
  ROUTING_WARMUP_REQUESTS = 1200
  REQUESTS_DRIVEN         = WARMUP_REQUESTS + WINDOWS * WINDOW_REQUESTS
  ROUTING_REQUESTS_DRIVEN = ROUTING_WARMUP_REQUESTS + WINDOWS * WINDOW_REQUESTS
  BODY                    = "Hello, World!"
  RESOURCE_PATH           = "/api/v1/resource57/123"
  RESOURCE_BODY           = %({"route":"resource","id":"123"})
  # Static builds paths under its dir per request: a cwd-relative dir would make bytes grow with the cwd's length.
  STATIC_DIR = "/azu-hot-path/public"

  enum Stack
    Azu
    AzuMin
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

  struct ResourceEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "application/json"
      Raw.new({route: "resource", id: params["id"]}.to_json)
    end
  end

  class NullIO < IO
    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
    end
  end

  # The URL routing.lua requests as its `n`th.
  def self.routing_path(n : Int32) : String
    "/api/v1/resource#{n % 100}/#{n % 997}"
  end

  # Allocated bytes per request on `path`: see `smallest_per_iteration`.
  def self.bytes_per_request(stack : Stack, path : String) : Float64
    processor = HTTP::Server::RequestProcessor.new(handler(stack))
    allocated_bytes(processor, requests(path, WARMUP_REQUESTS))
    smallest_per_iteration { allocated_bytes(processor, requests(path, WINDOW_REQUESTS)) }
  end

  # The same for the routing scenario: request n is `routing_path(n)` and n never restarts, so a measured path is new
  # to the router, which by then holds a full path cache, as under wrk.
  def self.bytes_per_routing_request(stack : Stack) : Float64
    processor = HTTP::Server::RequestProcessor.new(handler(stack))
    allocated_bytes(processor, routing_requests(1, ROUTING_WARMUP_REQUESTS))
    next_n = 1 + ROUTING_WARMUP_REQUESTS
    smallest_per_iteration do
      window = routing_requests(next_n, WINDOW_REQUESTS)
      next_n += WINDOW_REQUESTS
      allocated_bytes(processor, window)
    end
  end

  # Allocated bytes per call of the block. It is yielded, never captured: a block or proc argument would allocate its
  # closure inside the window. It runs on the caller's fiber, so a block that yields lets other fibers' garbage in.
  def self.bytes_per_call(& : ->) : Float64
    WARMUP_REQUESTS.times { yield }
    smallest_per_iteration { allocated_during { WINDOW_REQUESTS.times { yield } } }
  end

  # The raw response to `count` requests on one connection, so a stack that fails or 404s is caught instead of
  # measured as cheap.
  def self.response(stack : Stack, path : String, count : Int32 = 1) : String
    String.build { |output| HTTP::Server::RequestProcessor.new(handler(stack)).process(requests(path, count), output) }
  end

  # The smallest of several windows, because stray allocations (a timer, the scheduler) can only add to a window,
  # never remove from it.
  private def self.smallest_per_iteration(& : -> UInt64) : Float64
    (1..WINDOWS).min_of { yield }.to_f / WINDOW_REQUESTS
  end

  private def self.allocated_during(& : ->) : UInt64
    before = GC.stats.total_bytes
    yield
    GC.stats.total_bytes - before
  end

  # One keep-alive connection, as wrk's. The processor never yields (memory in, NullIO out), so nothing else runs in the
  # window; the fresh fiber starts, like a connection fiber, with no fiber-local state (RequestContext, Log context).
  private def self.allocated_bytes(processor : HTTP::Server::RequestProcessor, input : IO::Memory) : UInt64
    output = NullIO.new
    allocated = Channel(UInt64).new
    spawn { allocated.send allocated_during { processor.process(input, output) } }
    allocated.receive
  end

  private def self.requests(path : String, count : Int32) : IO::Memory
    IO::Memory.new(request(path) * count)
  end

  private def self.routing_requests(first : Int32, count : Int32) : IO::Memory
    IO::Memory.new((first...first + count).join { |n| request(routing_path(n)) })
  end

  private def self.request(path : String) : String
    "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n"
  end

  private def self.handler(stack : Stack) : HTTP::Handler | HTTP::Handler::HandlerProc
    case stack
    in .azu?      then azu_dispatcher
    in .azu_min?  then azu_min_dispatcher
    in .baseline? then baseline
    end
  end

  private def self.azu_app : Azu::App
    app = Azu::App.new
    app.config.env = Azu::Environment::Production
    app.routes do
      get "/plaintext", PlaintextEndpoint
      # They mirror the bench app's router size, which shapes the cost of finding a route
      {% for i in 0...100 %}
        get "/api/v1/resource{{ i }}/:id", ResourceEndpoint
      {% end %}
    end
    app
  end

  private def self.azu_dispatcher : HTTP::Handler
    app = azu_app
    static = Azu::Handler::Static.new(STATIC_DIR, fallthrough: true, cache_max_age: app.config.assets.cache_max_age)
    handlers = app.default_handlers.reject(Azu::Handler::Logger)
    app.dispatcher(handlers.map! { |candidate| candidate.is_a?(Azu::Handler::Static) ? static : candidate })
  end

  # The bench app's `bench_minimal_handlers`: what the router and endpoint cost without the default middleware.
  private def self.azu_min_dispatcher : HTTP::Handler
    azu_app.dispatcher([Azu::Handler::Rescuer.new] of HTTP::Handler)
  end

  private def self.baseline : HTTP::Handler::HandlerProc
    ->(context : HTTP::Server::Context) do
      path = context.request.path
      if path == "/plaintext"
        context.response.content_type = "text/plain"
        context.response.print BODY
      elsif path.starts_with?("/api/v1/resource")
        context.response.content_type = "application/json"
        context.response.print({route: "resource", id: path[path.rindex('/').not_nil! + 1..]}.to_json)
      end
    end
  end
end
