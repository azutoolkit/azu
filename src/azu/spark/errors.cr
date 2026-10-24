module Azu
  module Spark
    # Base class of failures a client may cause or learn about. The `code` is what the wire
    # protocol reports; the message is only echoed to clients in the development environment.
    class Error < Exception
      def code : String
        "internal"
      end
    end

    # The join token is malformed, tampered with, expired or names an unknown view.
    class InvalidToken < Error
      def code : String
        "invalid_token"
      end
    end

    # The state snapshot sent with a join is malformed, tampered with, expired, too large or was
    # issued for another page, session or component class. The client drops it and joins afresh.
    class InvalidSnapshot < Error
      def code : String
        "invalid_snapshot"
      end
    end

    # Raised from `mount` (see `Socket#reject!`) to refuse a connection.
    class Rejected < Error
      def code : String
        "rejected"
      end
    end

    # The client sent something malformed: bad JSON, a missing or mistyped event parameter...
    class BadRequest < Error
      def code : String
        "bad_request"
      end
    end

    # The event addressed a component that does not exist on this connection.
    class UnknownTarget < Error
      def code : String
        "unknown_target"
      end
    end

    # The component declares no handler for the event.
    class UnknownEvent < Error
      def code : String
        "unknown_event"
      end
    end

    # The event was made for another incarnation of its component tree than the one mounted now:
    # the snapshot it grew from was refused (expired, tampered, the app changed) and the page was
    # mounted afresh, so the user acted on a view that no longer exists. Never applied.
    class StaleEvent < Error
      def code : String
        "stale_event"
      end
    end

    # A connection exceeded a per connection cap such as the number of components.
    class LimitExceeded < Error
      def code : String
        "limit_exceeded"
      end
    end

    # Programmer or deployment mistake, raised while booting; never sent to clients.
    class ConfigurationError < Exception
    end
  end
end
