require "../store"

module Azu
  module Presence
    class Store
      # In-process store: one process, or several `Tracker`s sharing the instance in specs.
      class Memory < Store
        def initialize
          @topics = {} of String => Hash(String, Meta)
          @leases = {} of String => Time
          @mutex = Mutex.new
        end

        def put(topic : String, meta : Meta) : Nil
          @mutex.synchronize { (@topics[topic] ||= {} of String => Meta)[meta.ref] = meta }
        end

        def delete(topic : String, meta : Meta) : Nil
          evict(topic, [meta])
        end

        def stored(topic : String) : Array(Meta)
          @mutex.synchronize { @topics[topic]?.try(&.values) || [] of Meta }
        end

        def renew(node : String, expires_at : Time) : Nil
          @mutex.synchronize { @leases[node] = expires_at }
        end

        def leases : Hash(String, Time)
          @mutex.synchronize { @leases.dup }
        end

        def forget(nodes : Array(String)) : Nil
          @mutex.synchronize { nodes.each { |node| @leases.delete(node) } }
        end

        def evict(topic : String, metas : Array(Meta)) : Nil
          @mutex.synchronize do
            next unless entries = @topics[topic]?
            metas.each { |meta| entries.delete(meta.ref) }
            @topics.delete(topic) if entries.empty?
          end
        end
      end
    end
  end
end
