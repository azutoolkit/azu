require "http/server"

module Azu
  # Fiber-keyed record of the HTTP request being served, so lower layers (the
  # database instrumentation, loggers) can tie their work back to it without the
  # context being passed around. Entries live only for the duration of `scope`.
  module RequestContext
    class Info
      getter request_id : String
      getter method : String
      getter path : String
      property endpoint : String?
      getter fiber_id : UInt64

      def initialize(@request_id, @method, @path, @fiber_id, @endpoint = nil)
      end
    end

    # Random bytes for request ids, taken from the system's secure generator a chunk at a time: one
    # `getrandom` call serves many requests instead of one each. A request id is not a secret, but it
    # stays unguessable, which a counter or a generator seeded from the clock would not.
    private class IdEntropy
      CHUNK = 512

      def initialize
        @buffer = Bytes.new(CHUNK)
        @offset = CHUNK
        @mutex = Mutex.new
      end

      def hex(bytes : Int32) : String
        @mutex.synchronize do
          if @offset + bytes > CHUNK
            Random::Secure.random_bytes(@buffer)
            @offset = 0
          end
          hex = @buffer[@offset, bytes].hexstring
          @offset += bytes
          hex
        end
      end
    end

    @@mutex = Mutex.new
    @@contexts = {} of Fiber => Info
    @@entropy = IdEntropy.new

    # A new request id: `req_<unix ms>_<2 * random_bytes hex digits>`.
    def self.generate_id(random_bytes : Int32 = 8) : String
      "req_#{Time.utc.to_unix_ms}_#{@@entropy.hex(random_bytes)}"
    end

    def self.current? : Info?
      @@mutex.synchronize { @@contexts[Fiber.current]? }
    end

    # Runs the block with `context` registered for the current fiber. A scope that is already open
    # (e.g. from the RequestId handler) is reused. Looking for one and opening a new one is a single
    # critical section.
    def self.scope(context : HTTP::Server::Context, & : Info ->)
      fiber = Fiber.current
      request = context.request
      created = false
      info = @@mutex.synchronize do
        @@contexts[fiber]? || begin
          created = true
          @@contexts[fiber] = new_info(request, fiber)
        end
      end
      return yield info unless created

      begin
        yield info
      ensure
        @@mutex.synchronize { @@contexts.delete(fiber) }
      end
    end

    private def self.new_info(request : HTTP::Request, fiber : Fiber) : Info
      Info.new(request.headers["X-Request-ID"]? || generate_id(4), request.method, request.path, fiber.object_id)
    end

    # Runs the block with an explicit context (for jobs and specs).
    def self.with(request_id : String, method : String = "GET", path : String = "/", endpoint : String? = nil, &)
      fiber = Fiber.current
      previous = @@mutex.synchronize { @@contexts[fiber]? }
      @@mutex.synchronize { @@contexts[fiber] = Info.new(request_id, method, path, fiber.object_id, endpoint) }
      begin
        yield
      ensure
        @@mutex.synchronize do
          if previous
            @@contexts[fiber] = previous
          else
            @@contexts.delete(fiber)
          end
        end
      end
    end
  end
end
