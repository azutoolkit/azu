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
      # The request being served; nil for a context opened with `RequestContext.with` (jobs, specs).
      getter http_context : HTTP::Server::Context?
      # When the context was opened, so an error can say how long the request ran before it failed.
      getter started_at : Time::Instant = Time.instant

      def initialize(@request_id, @method, @path, @fiber_id, @endpoint = nil, @http_context = nil)
      end
    end

    # Random bytes for request ids, taken from the system's secure generator a chunk at a time: one
    # `getrandom` call serves many requests instead of one each. A request id is not a secret, but it
    # stays unguessable, which a counter or a generator seeded from the clock would not. It also keeps
    # the id's `req_<unix ms>_` formatted, once per millisecond rather than once per id.
    private class IdEntropy
      CHUNK = 512

      def initialize
        @buffer = Bytes.new(CHUNK)
        @offset = CHUNK
        @mutex = Mutex.new
        # "req_", the digits of a UInt64 and "_"
        @prefix = Bytes.new(ID_PREFIX.bytesize + 20 + 1)
        @prefix_size = 0
        @prefix_millis = UInt64::MAX # never a reading, so the first call formats
      end

      # Yields `req_<millis>_` and `bytes` random bytes no other call gets. Both are views of buffers, valid
      # only inside the block, which runs under the lock.
      def take(millis : UInt64, bytes : Int32, & : Bytes, Bytes -> T) : T forall T
        raise ArgumentError.new("random bytes must be between 1 and #{CHUNK}, got #{bytes}") unless 1 <= bytes <= CHUNK
        @mutex.synchronize do
          format_prefix(millis) unless millis == @prefix_millis
          if @offset + bytes > CHUNK
            Random::Secure.random_bytes(@buffer)
            @offset = 0
          end
          random = @buffer[@offset, bytes]
          @offset += bytes
          yield @prefix[0, @prefix_size], random
        end
      end

      private def format_prefix(millis : UInt64) : Nil
        digits = 1
        rest = millis
        while rest >= 10
          rest //= 10
          digits += 1
        end
        separator = ID_PREFIX.bytesize + digits
        ID_PREFIX.to_unsafe.copy_to(@prefix.to_unsafe, ID_PREFIX.bytesize)
        rest = millis
        (1..digits).each do |place|
          @prefix[separator - place] = '0'.ord.to_u8 + rest % 10
          rest //= 10
        end
        @prefix[separator] = '_'.ord.to_u8
        @prefix_size = separator + 1
        @prefix_millis = millis
      end
    end

    private ID_PREFIX  = "req_"
    private HEX_DIGITS = "0123456789abcdef"

    @@mutex = Mutex.new
    @@contexts = {} of Fiber => Info
    @@entropy = IdEntropy.new

    # :nodoc:
    #
    # A new request id: `req_<unix ms>_<2 * random_bytes hex digits>`; 1 to 512 random bytes.
    def self.generate_id(random_bytes : Int32 = 8) : String
      millis = Math.max(Time.utc.to_unix_ms, 0_i64).to_u64 # a clock before 1970 counts as 0
      @@entropy.take(millis, random_bytes) { |prefix, random| build_id(prefix, random) }
    end

    # The id written straight into one String: the prefix copied, the random bytes spelled in hex.
    private def self.build_id(prefix : Bytes, random : Bytes) : String
      capacity = prefix.size + random.size * 2

      String.new(capacity) do |buffer|
        prefix.copy_to(buffer, prefix.size)
        random.each_with_index do |byte, index|
          buffer[prefix.size + 2 * index] = HEX_DIGITS.to_unsafe[byte >> 4]
          buffer[prefix.size + 1 + 2 * index] = HEX_DIGITS.to_unsafe[byte & 0x0f]
        end
        {capacity, capacity}
      end
    end

    def self.current? : Info?
      @@mutex.synchronize { @@contexts[Fiber.current]? }
    end

    # Runs the block with `context` registered for the current fiber. A scope that is already open
    # (e.g. from the RequestId handler) is reused. Looking for one and opening a new one is a single
    # critical section.
    def self.scope(context : HTTP::Server::Context, & : Info ->)
      fiber = Fiber.current
      created = false
      info = @@mutex.synchronize do
        @@contexts[fiber]? || begin
          created = true
          @@contexts[fiber] = new_info(context, fiber)
        end
      end
      return yield info unless created

      begin
        yield info
      ensure
        @@mutex.synchronize { @@contexts.delete(fiber) }
      end
    end

    private def self.new_info(context : HTTP::Server::Context, fiber : Fiber) : Info
      request = context.request
      Info.new(request.headers["X-Request-ID"]? || generate_id(4), request.method, request.path, fiber.object_id, http_context: context)
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
