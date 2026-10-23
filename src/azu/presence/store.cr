require "./meta"

module Azu
  module Presence
    # Where the metas of every node live (Strategy). A store keeps, per topic, the metas by `ref`, and one
    # lease per node. It never decides what is alive: `live` does, the same way for every store.
    abstract class Store
      abstract def put(topic : String, meta : Meta) : Nil
      abstract def delete(topic : String, meta : Meta) : Nil
      # Every stored meta of *topic*, expired or not.
      abstract def stored(topic : String) : Array(Meta)
      abstract def renew(node : String, expires_at : Time) : Nil
      abstract def leases : Hash(String, Time)
      abstract def forget(nodes : Array(String)) : Nil
      abstract def evict(topic : String, metas : Array(Meta)) : Nil

      def shutdown : Nil
      end

      # The metas of nodes whose lease is still valid at *now*. Metas of nodes expired for more than *grace*
      # (or without a lease) are removed on the way, and so are those leases.
      def live(topic : String, now : Time, grace : Time::Span) : Array(Meta)
        leases = self.leases
        alive, expired = stored(topic).partition { |meta| (lease = leases[meta.node]?) && lease > now }
        evict(topic, expired.select { |meta| lapsed?(leases[meta.node]?, now - grace) })
        alive
      end

      # Drops the leases that expired before *now - grace*.
      def prune_leases(now : Time, grace : Time::Span) : Nil
        forget(leases.select { |_, expires_at| expires_at <= now - grace }.keys)
      end

      private def lapsed?(lease : Time?, limit : Time) : Bool
        lease.nil? || lease <= limit
      end
    end
  end
end
