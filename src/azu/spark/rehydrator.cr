require "log"
require "./configuration"
require "./snapshot"

module Azu
  module Spark
    # Brings the components of a page back to the state of an earlier connection: `load` opens the
    # snapshot a client sent with its `join`, and `restore` hands each component its state as the
    # session mounts it (children are mounted while the parent renders, so states wait here until
    # their turn).
    class Rehydrator
      # The generation of the snapshot that was loaded, if it named one.
      getter generation : String? = nil

      def initialize(@config : Configuration)
        @pending = {} of String => Snapshot::Member
      end

      def load(token : String?, root_id : String, session : Hash(String, String)) : Nil
        return unless token
        opened = Snapshot.read(token, root_id, session, @config.secret, @config.max_snapshot_size)
        @generation = opened.generation
        @pending.merge!(opened.members)
      end

      # Restores *component* (mounted as *id*) from its pending state, if any. A state recorded for
      # another class is refused: the snapshot does not describe this component.
      def restore(component : Component, id : String) : Nil
        return unless member = @pending.delete(id)
        unless member.type == component.class.name
          raise InvalidSnapshot.new("snapshot of #{id} was taken from #{member.type}, not #{component.class.name}")
        end
        raise InvalidSnapshot.new("state of #{id} is not an object") unless member.state.as_h?
        component.__spark_restore(member.state)
      rescue JSON::ParseException | JSON::SerializableError
        Log.for("Azu::Spark").warn { "State snapshot of #{component.class.name} no longer fits its declaration" }
      end

      def clear : Nil
        @generation = nil
        @pending.clear
      end
    end
  end
end
