require "./entry"
require "./errors"

module Azu
  module Spark
    # The components of ONE connection. A client can only address components in its own
    # registry, so ids learned from other connections are useless, and tearing a connection
    # down can never affect anyone else.
    class Registry
      getter owner : String
      getter max_size : Int32

      def initialize(@owner : String, @max_size : Int32)
        @entries = {} of String => Entry
        @mutex = Mutex.new
      end

      def add(entry : Entry) : Entry
        @mutex.synchronize do
          raise LimitExceeded.new("too many components on this connection") if @entries.size >= @max_size
          raise BadRequest.new("component id already in use") if @entries.has_key?(entry.id)
          @entries[entry.id] = entry
        end
      end

      def []?(id : String) : Entry?
        @mutex.synchronize { @entries[id]? }
      end

      def [](id : String) : Entry
        self[id]? || raise UnknownTarget.new("no such component")
      end

      def delete(id : String) : Entry?
        @mutex.synchronize { @entries.delete(id) }
      end

      def size : Int32
        @mutex.synchronize { @entries.size }
      end

      def entries : Array(Entry)
        @mutex.synchronize { @entries.values }
      end

      # Removes and returns everything, for connection teardown.
      def drain : Array(Entry)
        @mutex.synchronize do
          @entries.values.tap { @entries.clear }
        end
      end
    end
  end
end
