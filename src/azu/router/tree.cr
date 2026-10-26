require "../method"

module Azu
  class Router
    # :nodoc:
    # Routes by path segment: a node per segment, its static children keyed by the segment's bytes, and on the node a
    # route ends at, one payload per `Azu::Method`. `find` reads the request path in place: the segment boundaries are
    # byte offsets kept on the stack and a static child is looked up by a slice of the path, so finding a static route
    # allocates nothing.
    #
    # Every `add` happens before serving; `find` then only reads the tree, so any fiber or thread may call it. A find
    # visits each node at most once (the static child, then the parameter, then the glob, moving on when one dead-ends),
    # so it costs at most one step per node, and it refuses a path of more segments than any route can take before
    # reading it whole.
    class Tree(T)
      private SLASH = '/'.ord.to_u8
      # How many offsets `find` keeps on the stack: a slash per segment plus the path's end, so a path of more than
      # STACK_BOUNDS - 1 (31) segments has them on the heap when a route is that deep, and is cut short otherwise.
      private STACK_BOUNDS = 32
      # The segment count of a path cut short: more than any route has, so it ends at no node and only a glob takes it
      private DEEPER = Int32::MAX

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
        # Nil when the route has none. Declared first, so a static find reads it next to the object header.
        @params : Array(Param)?
        getter payload : T
        getter path : String

        def initialize(@payload : T, @path : String, params : Array(Param))
          @params = params unless params.empty?
        end

        # The raw values of the route's parameters in `path`; nil when it has none.
        def params(path : String, bounds : Slice(Int32)) : Hash(String, String)?
          return unless list = @params

          # A capacity takes the 8-entry minimum (208 B); without one, the first insert grows the Hash to 4 (112 B)
          values = list.size > 4 ? Hash(String, String).new(initial_capacity: list.size) : Hash(String, String).new
          list.each do |param|
            from = bounds[param.segment] + 1
            to = param.glob ? bounds[-1] : bounds[param.segment + 1]
            values[param.name] = String.new(path.to_unsafe + from, Math.max(to - from, 0))
          end
          values
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

        # The route for `method` below this node, reached by the segments before `bounds[depth]`; the path has `segments`.
        def search(path : String, bounds : Slice(Int32), segments : Int32, depth : Int32, method : Azu::Method) : Entry(T)?
          return entry(method) || @glob.try(&.entry(method)) if depth == segments

          from = bounds[depth] + 1
          segment = Bytes.new(path.to_unsafe + from, bounds[depth + 1] - from, read_only: true)
          @static.try(&.[segment]?).try(&.search(path, bounds, segments, depth + 1, method)) ||
            @dynamic.try(&.search(path, bounds, segments, depth + 1, method)) ||
            @glob.try(&.entry(method))
        end
      end

      def initialize
        @root = Node(T).new
        @names = {} of String => String
        # The segment count of the deepest route, and whether a glob route takes paths of any depth
        @deepest = 0
        @any_glob = false
      end

      def add(method : Azu::Method, path : String, payload : T) : Nil
        node = @root
        params = [] of Param
        segments = segments(path)
        segments.each_with_index do |segment, index|
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
        @deepest = Math.max(@deepest, segments.size)
        @any_glob ||= params.last?.try(&.glob) || false
      end

      # Trailing slashes are ignored, on the request path as on the route paths.
      def find(method : Azu::Method, path : String) : Match(T)?
        bytes = path.to_slice
        size = bytes.size
        while size > 0 && bytes[size - 1] == SLASH
          size -= 1
        end
        return if size > 0 && bytes[0] != SLASH

        stack = uninitialized StaticArray(Int32, STACK_BOUNDS)
        return unless cut = cut(bytes[0, size], stack.to_slice)
        bounds, segments = cut
        entry = @root.search(path, bounds, segments, 0, method)
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

      # The offset of each slash of `path`, then its size: segment `i` lies between `bounds[i]` and `bounds[i + 1]`. With
      # the path's segment count; nil as soon as it has more than any route and no glob route can take them. A path of
      # more segments than the deepest route is cut after the offsets a route reads, so a long path costs no more than a
      # short one, and its count is DEEPER. The offsets are kept in `stack` unless the deepest route has more than
      # STACK_BOUNDS - 2 (30) segments.
      private def cut(path : Bytes, stack : Slice(Int32)) : {Slice(Int32), Int32}?
        bounds = stack
        count = 0
        path.each_with_index do |byte, offset|
          next unless byte == SLASH
          return unless count < @deepest || @any_glob
          if count > @deepest # the offsets any route reads are known: the rest is a glob's
            bounds[count] = path.size
            return {bounds[0, count + 1], DEEPER}
          end
          bounds = on_heap(stack, count) if count == stack.size - 1
          bounds[count] = offset
          count += 1
        end
        bounds[count] = path.size
        {bounds[0, count + 1], count}
      end

      # The first `count` offsets of `stack` on the heap, with room for those of the deepest route and the path's end.
      private def on_heap(stack : Slice(Int32), count : Int32) : Slice(Int32)
        Slice(Int32).new(@deepest + 2).tap(&.copy_from(stack.to_unsafe, count))
      end
    end
  end
end
