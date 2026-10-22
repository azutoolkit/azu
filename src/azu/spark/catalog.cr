require "json"
require "./errors"

module Azu
  module Spark
    # The components that may be mounted from a signed join token: those declared `mountable`.
    # Filled while the program loads (each `mountable` class registers itself) and only read afterwards.
    module Catalog
      @@builders = {} of String => Proc(JSON::Any, Component)

      def self.register(name : String, &builder : JSON::Any -> Component) : Nil
        @@builders[name] = builder
      end

      # Instantiates *name* with the props stored in a join token.
      def self.build(name : String, props : JSON::Any) : Component
        builder = @@builders[name]? || raise InvalidToken.new("unknown view #{name}")
        builder.call(props)
      rescue ex : JSON::ParseException | JSON::SerializableError | KeyError
        raise InvalidToken.new("props of #{name} no longer match its declaration")
      end

      def self.registered?(name : String) : Bool
        @@builders.has_key?(name)
      end
    end
  end
end
