require "../method"

module Azu
  class Router
    # :nodoc:
    # Routes by path segment: a node per segment, its static children keyed by the segment's bytes, and on the node a
    # route ends at, one payload per `Azu::Method`. `find` reads the request path in place: the segment boundaries are
    # byte offsets kept on the stack and a static child is looked up by a slice of the path, so finding a static route
    # allocates nothing.
    class Tree(T)
      private SLASH = '/'.ord.to_u8
      # How many offsets `find` keeps on the stack; a path of more segments has them on the heap.
      private STACK_BOUNDS = 32

      # A route `add` refuses.
      class Error < Exception
      end

      # The same method and path were added twice; Router reports it as `Router::DuplicateRoute`.
      class DuplicateError < Error
      end

      # What `find` returns: the route's payload and, when its path has parameters, their raw values.
      struct Match(T)
        getter params : Hash(String, String)?

        def initialize(@entry : Entry(T), @params : Hash(String, String)?)
        end

        # Read from the route, so a find never copies the payload.
        def payload : T
          @entry.payload
        end
      end

      # :nodoc:
      # A parameter of a route: its interned name and the index of the segment it reads (a glob, to the end of the path).
      record Param, name : String, segment : Int32, glob : Bool

      # :nodoc:
      class Entry(T)
        getter payload : T
        getter path : String

        def initialize(@payload : T, @path : String, @params : Array(Param))
        end

        # The raw values of the route's parameters in `path`; nil when it has none.
        def params(path : String, bounds : Slice(Int32)) : Hash(String, String)?
          return if @params.empty?

          @params.each_with_object(Hash(String, String).new(initial_capacity: @params.size)) do |param, values|
            from = bounds[param.segment] + 1
            to = param.glob ? bounds[-1] : bounds[param.segment + 1]
            values[param.name] = String.new(path.to_unsafe + from, Math.max(to - from, 0))
          end
        end
      end

      # :nodoc:
      class Node(T)
        @static : Hash(Bytes, Node(T))?
        @dynamic : Node(T)?
        @glob : Node(T)?
        # One slot per `Azu::Method`, indexed by its value
        {% begin %}
          @entries = StaticArray(Entry(T)?, {{ Azu::Method.constants.size }}).new(nil)
        {% end %}

        def static(segment : String) : Node(T)
          (@static ||= {} of Bytes => Node(T))[segment.to_slice] ||= Node(T).new
        end

        def dynamic : Node(T)
          @dynamic ||= Node(T).new
        end

        def glob : Node(T)
          @glob ||= Node(T).new
        end

        def entry(method : Azu::Method) : Entry(T)?
          @entries[method.value]
        end

        def add(method : Azu::Method, entry : Entry(T)) : Nil
          if existing = entry(method)
            raise DuplicateError.new("#{method.to_s.upcase} #{entry.path} is already routed as #{existing.path}")
          end
          @entries[method.value] = entry
        end

        # The route for `method` below this node, reached by the segments before `bounds[depth]`.
        def search(path : String, bounds : Slice(Int32), depth : Int32, method : Azu::Method) : Entry(T)?
          return entry(method) || @glob.try(&.entry(method)) if depth == bounds.size - 1

          from = bounds[depth] + 1
          segment = Bytes.new(path.to_unsafe + from, bounds[depth + 1] - from, read_only: true)
          @static.try(&.[segment]?).try(&.search(path, bounds, depth + 1, method)) ||
            @dynamic.try(&.search(path, bounds, depth + 1, method)) ||
            @glob.try(&.entry(method))
        end
      end

      def initialize
        @root = Node(T).new
        @names = {} of String => String
      end

      def add(method : Azu::Method, path : String, payload : T) : Nil
        node = @root
        params = [] of Param
        segments(path).each_with_index do |segment, index|
          case segment[0]?
          when ':', '*'
            glob = segment.starts_with?('*')
            params << Param.new(intern(segment), index, glob)
            node = glob ? node.glob : node.dynamic
          else
            node = node.static(segment)
          end
        end
        node.add method, Entry(T).new(payload, path, params)
      end

      # Trailing slashes aside, as Router strips them from the request path.
      def find(method : Azu::Method, path : String) : Match(T)?
        bytes = path.to_slice
        size = bytes.size
        while size > 0 && bytes[size - 1] == SLASH
          size -= 1
        end
        return if size > 0 && bytes[0] != SLASH

        stack = uninitialized StaticArray(Int32, STACK_BOUNDS)
        bounds = bounds(bytes[0, size], stack.to_slice)
        entry = @root.search(path, bounds, 0, method)
        Match(T).new(entry, entry.params(path, bounds)) if entry
      end

      # The segments of a route path, trailing slashes aside, checked before the tree changes.
      private def segments(path : String) : Array(String)
        raise Error.new("route path #{path.inspect} must start with /") unless path.starts_with?('/')
        segments = path.rstrip('/').split('/').skip(1)
        raise Error.new("#{path}: a glob must be the last segment") if segments[0...-1].any?(&.starts_with?('*'))
        segments
      end

      # The parameter name of `segment`, the same String for every route that uses it.
      private def intern(segment : String) : String
        name = segment[1..]
        @names[name] ||= name
      end

      # The offset of each slash of `path`, then its size: segment `i` lies between `bounds[i]` and `bounds[i + 1]`.
      private def bounds(path : Bytes, stack : Slice(Int32)) : Slice(Int32)
        count = path.count(SLASH)
        bounds = count < stack.size ? stack[0, count + 1] : Slice(Int32).new(count + 1)
        index = -1
        path.each_with_index { |byte, offset| bounds[index += 1] = offset if byte == SLASH }
        bounds[count] = path.size
        bounds
      end
    end
  end
end
