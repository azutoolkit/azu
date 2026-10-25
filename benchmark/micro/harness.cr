require "ecr"
require "../../src/azu"
require "../apps/common/bench"

# Bytes and time per request of three stacks, each driven through the RequestProcessor HTTP::Server builds per
# connection: the default Azu stack, azu-min (router, endpoint and Rescuer) and a hand-written baseline handler. The
# difference over the baseline is the framework's cost. `bytes_per_call` measures a block the same way, for component
# checks. The routes mirror benchmark/apps/azu, except that one resource endpoint serves all 100 routes with a
# simplified body (`{"route":"resource","id":...}`, the bench app has a struct per route); that does not change the
# difference over the baseline. `/template` renders the bench app's template as the bench apps do: through `view` on
# the Azu stacks, from ECR on the baseline.
module HotPath
  WARMUP_REQUESTS =  200
  WINDOW_REQUESTS = 2000
  WINDOWS         =    3
  # More paths than the router's path cache holds (1000). Once it is full `PathCache#set` returns early, so measured
  # requests carry no cache insert (each dups the cached hashes, which would inflate bytes) and every one misses.
  ROUTING_WARMUP_REQUESTS = 1200
  BODY                    = "Hello, World!"
  RESOURCE_PATH           = "/api/v1/resource57/123"
  RESOURCE_BODY           = %({"route":"resource","id":"123"})
  # Static builds paths under its dir per request: a cwd-relative dir would make bytes grow with the cwd's length.
  STATIC_DIR    = "/azu-hot-path/public"
  TEMPLATE_PATH = "/template"
  # The bench apps' templates (template.jinja, template.ecr). Read once, when the first render compiles them.
  TEMPLATE_DIR = File.expand_path("../apps/common", __DIR__)

  # Bytes and nanoseconds per request; `measure` takes the smallest of each over its windows, maybe from different ones.
  record Measurement, bytes : Float64, ns : Float64

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

  # benchmark/apps/azu's ItemsPage and TemplateEndpoint.
  struct ItemsPage
    include Azu::Response
    include Azu::Templates::Renderable

    def render
      items = Bench::ITEMS.map do |item|
        {"id" => Crinja::Value.new(item.id), "name" => Crinja::Value.new(item.name), "price" => Crinja::Value.new(item.price)}
      end
      view "template.jinja", {"items" => items}
    end
  end

  struct TemplateEndpoint
    include Azu::Endpoint(NoRequest, ItemsPage)

    def call : ItemsPage
      content_type "text/html"
      ItemsPage.new
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

  # `path` on one connection, measured after a warmup: see `smallest`.
  def self.measure(stack : Stack, path : String) : Measurement
    processor = HTTP::Server::RequestProcessor.new(handler(stack))
    window(processor, requests(path, WARMUP_REQUESTS))
    smallest(Array.new(WINDOWS) { window(processor, requests(path, WINDOW_REQUESTS)) })
  end

  # The same for the routing scenario, over the request numbers of `routing_windows`.
  def self.measure_routing(stack : Stack) : Measurement
    processor = HTTP::Server::RequestProcessor.new(handler(stack))
    warmup, *measured = routing_windows
    window(processor, routing_requests(warmup))
    smallest(measured.map { |numbers| window(processor, routing_requests(numbers)) })
  end

  # routing.lua's request numbers n, in order: the warmup, then each measured window. n never restarts, so a measured
  # path is new to the router, which by then holds a full path cache, as under wrk.
  def self.routing_windows : Array(Range(Int32, Int32))
    windows = [1..ROUTING_WARMUP_REQUESTS]
    WINDOWS.times do
      first = windows.last.end + 1
      windows << (first..first + WINDOW_REQUESTS - 1)
    end
    windows
  end

  # Allocated bytes per call of the block. It is yielded, never captured: a block or proc argument would allocate its
  # closure inside the window. It runs on the caller's fiber, so a block that yields lets other fibers' garbage in.
  def self.bytes_per_call(& : ->) : Float64
    WARMUP_REQUESTS.times { yield }
    smallest(Array.new(WINDOWS) { per_request { WINDOW_REQUESTS.times { yield } } }).bytes
  end

  # The raw response to `count` requests on one connection, so a stack that fails or 404s is caught instead of
  # measured as cheap.
  def self.response(stack : Stack, path : String, count : Int32 = 1) : String
    String.build { |output| HTTP::Server::RequestProcessor.new(handler(stack)).process(requests(path, count), output) }
  end

  # The smallest of several windows, because stray work (a timer, the scheduler, a collection) can only add to a
  # window, never remove from it.
  private def self.smallest(windows : Array(Measurement)) : Measurement
    Measurement.new(windows.min_of(&.bytes), windows.min_of(&.ns))
  end

  # Per request of a WINDOW_REQUESTS window. The clock reads allocate nothing and sit inside the GC reads, so they add
  # no bytes and GC.stats adds no time.
  private def self.per_request(& : ->) : Measurement
    bytes_before = GC.stats.total_bytes
    elapsed = Time.measure { yield }
    bytes = GC.stats.total_bytes - bytes_before
    Measurement.new(bytes.to_f / WINDOW_REQUESTS, elapsed.total_nanoseconds / WINDOW_REQUESTS)
  end

  # One keep-alive connection, as wrk's, over an input built beforehand. The processor never yields (memory in, NullIO
  # out), so nothing else runs in the window; the fresh fiber starts, like a connection fiber, with no fiber-local state
  # (RequestContext, Log context).
  private def self.window(processor : HTTP::Server::RequestProcessor, input : IO::Memory) : Measurement
    output = NullIO.new
    measurement = Channel(Measurement).new
    spawn { measurement.send per_request { processor.process(input, output) } }
    measurement.receive
  end

  private def self.requests(path : String, count : Int32) : IO::Memory
    IO::Memory.new(request(path) * count)
  end

  private def self.routing_requests(numbers : Range(Int32, Int32)) : IO::Memory
    IO::Memory.new(numbers.join { |n| request(routing_path(n)) })
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
    # As the bench app runs (CRYSTAL_ENV=production): templates parsed once, never reloaded, whatever CRYSTAL_ENV is here
    app.config.template_hot_reload = false
    app.config.templates.path = TEMPLATE_DIR
    app.routes do
      get "/plaintext", PlaintextEndpoint
      get TEMPLATE_PATH, TemplateEndpoint
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
      elsif path == TEMPLATE_PATH
        context.response.content_type = "text/html"
        context.response.print render_template
      elsif path.starts_with?("/api/v1/resource")
        context.response.content_type = "application/json"
        context.response.print({route: "resource", id: path[path.rindex('/').not_nil! + 1..]}.to_json)
      end
    end
  end

  # benchmark/apps/baseline's render_template.
  private def self.render_template : String
    items = Bench::ITEMS
    ECR.render "#{__DIR__}/../apps/common/template.ecr"
  end
end
