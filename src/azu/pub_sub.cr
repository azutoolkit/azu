require "json"
require "log"
require "./pub_sub/*"

module Azu
  # Topic based publish/subscribe shared by `Azu::Channel` and `Azu::Spark` components.
  #
  # Handlers run on the broadcaster's fiber (or the backend's listener fiber), so they
  # must be quick and non-blocking: enqueue the message and return.
  #
  # ```
  # subscription = Azu::PubSub.subscribe("todos") { |message| puts message.payload }
  # Azu::PubSub.broadcast("todos", "changed")
  # subscription.cancel
  # ```
  #
  # The default backend is in-process memory. Select another one once, at boot:
  #
  # ```
  # Azu::PubSub.backend = Azu::PubSub::Redis.new("redis://localhost:6379/0")
  # ```
  module PubSub
    record Message, topic : String, payload : String do
      # Decodes the payload as JSON into *type*.
      def json(type : T.class) : T forall T
        T.from_json(payload)
      end
    end

    @@backend : Backend? = nil
    @@mutex = Mutex.new

    def self.backend : Backend
      @@mutex.synchronize { @@backend ||= Memory.new }
    end

    # Replaces the backend, shutting down the previous one.
    def self.backend=(backend : Backend) : Backend
      previous = @@mutex.synchronize do
        old = @@backend
        @@backend = backend
        old
      end
      previous.try(&.shutdown)
      backend
    end

    def self.subscribe(topic : String, &handler : Message ->) : Subscription
      backend.subscribe(topic, &handler)
    end

    def self.broadcast(topic : String, payload : String) : Nil
      backend.broadcast(topic, payload)
    end

    # Broadcasts *data* encoded as JSON.
    def self.broadcast(topic : String, data : _) : Nil
      broadcast(topic, data.to_json)
    end

    # Stops the backend and forgets it; the next use starts a fresh in-memory backend.
    def self.shutdown : Nil
      previous = @@mutex.synchronize do
        old = @@backend
        @@backend = nil
        old
      end
      previous.try(&.shutdown)
    end
  end
end
