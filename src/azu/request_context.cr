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

    @@mutex = Mutex.new
    @@contexts = {} of Fiber => Info

    def self.current? : Info?
      @@mutex.synchronize { @@contexts[Fiber.current]? }
    end

    # Runs the block with `context` registered for the current fiber. A scope
    # that is already open (e.g. from the RequestId handler) is reused.
    def self.scope(context : HTTP::Server::Context, & : Info ->)
      fiber = Fiber.current
      existing = @@mutex.synchronize { @@contexts[fiber]? }
      return yield existing if existing

      request = context.request
      info = Info.new(
        request.headers["X-Request-ID"]? || "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(4)}",
        request.method, request.path, fiber.object_id
      )
      @@mutex.synchronize { @@contexts[fiber] = info }
      begin
        yield info
      ensure
        @@mutex.synchronize { @@contexts.delete(fiber) }
      end
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
