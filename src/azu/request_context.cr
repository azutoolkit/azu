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

      # Yields `bytes` random bytes no other call gets. They are a view of the buffer, valid only inside the
      # block, which runs under the lock.
      def take(bytes : Int32, & : Bytes -> T) : T forall T
        raise ArgumentError.new("random bytes must be between 1 and #{CHUNK}, got #{bytes}") unless 1 <= bytes <= CHUNK
        @mutex.synchronize do
          if @offset + bytes > CHUNK
            Random::Secure.random_bytes(@buffer)
            @offset = 0
          end
          random = @buffer[@offset, bytes]
          @offset += bytes
          yield random
        end
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
      @@entropy.take(random_bytes) { |random| build_id(millis, random) }
    end

    # The id written straight into one String: no String for the digits or for the hex.
    private def self.build_id(millis : UInt64, random : Bytes) : String
      digits = 1
      rest = millis
      while rest >= 10
        rest //= 10
        digits += 1
      end
      separator = ID_PREFIX.bytesize + digits
      capacity = separator + 1 + random.size * 2

      String.new(capacity) do |buffer|
        ID_PREFIX.to_unsafe.copy_to(buffer, ID_PREFIX.bytesize)
        rest = millis
        (1..digits).each do |place|
          buffer[separator - place] = '0'.ord.to_u8 + rest % 10
          rest //= 10
        end
        buffer[separator] = '_'.ord.to_u8
        random.each_with_index do |byte, index|
          buffer[separator + 1 + 2 * index] = HEX_DIGITS.to_unsafe[byte >> 4]
          buffer[separator + 2 + 2 * index] = HEX_DIGITS.to_unsafe[byte & 0x0f]
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
