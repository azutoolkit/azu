module Azu
  module PubSub
    # Contract implemented by every PubSub transport.
    abstract class Backend
      abstract def subscribe(topic : String, &handler : Message ->) : Subscription
      abstract def unsubscribe(subscription : Subscription) : Nil
      abstract def broadcast(topic : String, payload : String) : Nil

      # Releases fibers and connections owned by the backend.
      def shutdown : Nil
      end
    end
  end
end
