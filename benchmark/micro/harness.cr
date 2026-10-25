require "../../src/azu"

# Allocation harness: bytes allocated per request by Azu's stacks and by a hand-written handler, both
# driven through HTTP::Server's own RequestProcessor (what the server builds per connection), so the
# difference is the framework's cost. The types mirror benchmark/apps/azu/src/app.cr.
module HotPath
  WARMUP_REQUESTS =  200
  WINDOW_REQUESTS = 2000
  WINDOWS         =    3
  RESOURCE_PREFIX = "/api/v1/resource"

  struct NoRequest
    include Azu::Request
  end

  struct Raw
    include Azu::Response

    def initialize(@body : String)
    end

    def render
      @body
    end
  end

  struct PlaintextEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "text/plain"
      Raw.new("Hello, World!")
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
    def read(slice : Bytes)
      0
    end

    def write(slice : Bytes) : Nil
    end
  end

  @@processors = {} of Symbol => HTTP::Server::RequestProcessor

  # Allocated bytes per request on `path`: the smallest of several windows, because stray
  # allocations (a timer, the scheduler) can only add to a window, never remove from it.
  def self.bytes_per_request(stack : Symbol, path : String) : Float64
    processor = @@processors[stack] ||= HTTP::Server::RequestProcessor.new(handler(stack))
    allocated_bytes(processor, path, WARMUP_REQUESTS)
    smallest = (1..WINDOWS).min_of { allocated_bytes(processor, path, WINDOW_REQUESTS) }
    smallest.to_f / WINDOW_REQUESTS
  end

  # The processor runs in a fresh fiber so no other fiber's allocations land between the two reads,
  # and every request rides one keep-alive connection, as wrk's do.
  private def self.allocated_bytes(processor : HTTP::Server::RequestProcessor, path : String, requests : Int32) : UInt64
    input = IO::Memory.new("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n" * requests)
    output = NullIO.new
    allocated = Channel(UInt64).new
    spawn do
      before = GC.stats.total_bytes
      processor.process(input, output)
      allocated.send GC.stats.total_bytes - before
    end
    bytes = allocated.receive
    raise "keep-alive stopped at byte #{input.pos} of #{input.size}" unless input.pos == input.size
    bytes
  end

  private def self.handler(stack : Symbol) : HTTP::Handler | HTTP::Handler::HandlerProc
    case stack
    when :azu
      app = azu_app
      app.dispatcher(app.default_handlers.reject(Azu::Handler::Logger))
    when :azu_min  then azu_app.dispatcher([Azu::Handler::Rescuer.new] of HTTP::Handler)
    when :baseline then baseline
    else
      raise ArgumentError.new("unknown stack #{stack.inspect}")
    end
  end

  private def self.azu_app : Azu::App
    app = Azu::App.new
    app.config.env = Azu::Environment::Production
    app.routes do
      get "/plaintext", PlaintextEndpoint
      {% for i in 0...100 %}
        get "/api/v1/resource{{ i }}/:id", ResourceEndpoint
      {% end %}
    end
    app
  end

  private def self.baseline : HTTP::Handler::HandlerProc
    ->(context : HTTP::Server::Context) do
      path = context.request.path
      if path == "/plaintext"
        context.response.content_type = "text/plain"
        context.response.print "Hello, World!"
      elsif path.starts_with?(RESOURCE_PREFIX)
        context.response.content_type = "application/json"
        context.response.print({route: "resource", id: path.split('/').last}.to_json)
      end
      nil
    end
  end
end
