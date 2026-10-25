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
      class Entry(T)
        getter payload : T

        def initialize(@payload : T)
        end
      end

      # :nodoc:
      class Node(T)
        @static : Hash(Bytes, Node(T))?
        # One slot per `Azu::Method`, indexed by its value
        {% begin %}
          @entries = StaticArray(Entry(T)?, {{ Azu::Method.constants.size }}).new(nil)
        {% end %}

        def static(segment : String) : Node(T)
          (@static ||= {} of Bytes => Node(T))[segment.to_slice] ||= Node(T).new
        end

        def add(method : Azu::Method, entry : Entry(T)) : Nil
          @entries[method.value] = entry
        end

        # The route for `method` below this node, reached by the segments before `bounds[depth]`.
        def search(path : String, bounds : Slice(Int32), depth : Int32, method : Azu::Method) : Entry(T)?
          return @entries[method.value] if depth == bounds.size - 1

          from = bounds[depth] + 1
          segment = Bytes.new(path.to_unsafe + from, bounds[depth + 1] - from, read_only: true)
          @static.try(&.[segment]?).try(&.search(path, bounds, depth + 1, method))
        end
      end

      def initialize
        @root = Node(T).new
      end

      def add(method : Azu::Method, path : String, payload : T) : Nil
        node = path.lchop('/').split('/').reduce(@root) { |parent, segment| parent.static(segment) }
        node.add method, Entry(T).new(payload)
      end

      def find(method : Azu::Method, path : String) : Match(T)?
        return unless path.starts_with?('/')

        stack = uninitialized StaticArray(Int32, STACK_BOUNDS)
        entry = @root.search(path, bounds(path.to_slice, stack.to_slice), 0, method)
        Match(T).new(entry, nil) if entry
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
