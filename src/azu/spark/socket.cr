require "json"
require "../pub_sub"
require "./connection_info"
require "./errors"
require "./update"

module Azu
  module Spark
    # The server side handle of one mounted component: connection metadata, change tracking
    # and every way a component talks to the outside world (PubSub, timers, flash messages,
    # browser events, navigation).
    #
    # Assigns themselves are typed instance variables declared with `state`; the socket records
    # which of them changed so only affected components are rendered again.
    class Socket
      getter id : String
      getter parent_id : String?
      getter connection : ConnectionInfo
      # Signed claims issued with the page (`Azu::Spark.render(..., session: {...})`).
      getter session : Hash(String, String)
      getter flash = {} of String => String
      getter changed = Set(String).new
      getter? connected : Bool

      def initialize(@id : String, @parent_id : String?, @host : Session?, @connection : ConnectionInfo,
                     @session : Hash(String, String), @connected : Bool)
      end

      # Socket of a component that is not driven by a session, for unit tests of a single component.
      def self.detached(id : String = "detached") : Socket
        new(id, nil, nil, ConnectionInfo.detached, {} of String => String, false)
      end

      def headers : HTTP::Headers
        connection.headers
      end

      def remote_address : String?
        connection.remote_address
      end

      def changed? : Bool
        !changed.empty?
      end

      # Records that the assign *name* changed and schedules a render.
      def mark_changed(name : String) : Nil
        @changed << name
        @host.try(&.mark_dirty(id))
      end

      def clear_changes : Nil
        @changed.clear
      end

      # Refuses the connection from `mount`: nothing is rendered and the client is told it was rejected.
      def reject!(reason : String = "rejected") : NoReturn
        raise Rejected.new(reason)
      end

      def put_flash(kind : String, message : String) : Nil
        @flash[kind] = message
        mark_changed("flash")
      end

      def clear_flash(kind : String? = nil) : Nil
        kind ? @flash.delete(kind) : @flash.clear
        mark_changed("flash")
      end

      # Dispatches the DOM event `spark:<name>` on the component's element in the browser.
      def push_event(name : String, payload : _ = nil) : Nil
        @host.try(&.push_event(id, name, JSON.parse(payload.to_json)))
      end

      # Navigates the browser to a path of this application.
      def redirect(to : String, replace : Bool = false) : Nil
        unless to.starts_with?('/') && !to.starts_with?("//") && !to.includes?('\\')
          raise ArgumentError.new("redirect target must be a path of this application, got #{to.inspect}")
        end
        @host.try(&.redirect(to, replace))
      end

      # Delivers PubSub broadcasts of *topic* to `handle_info` until the component unmounts.
      # Does nothing while rendering the initial HTTP response, which has no live connection.
      def subscribe(topic : String) : Nil
        @host.try(&.subscribe(id, topic)) if connected?
      end

      def unsubscribe(topic : String) : Nil
        @host.try(&.unsubscribe(id, topic))
      end

      def broadcast(topic : String, payload : String) : Nil
        PubSub.broadcast(topic, payload)
      end

      def broadcast(topic : String, payload : _) : Nil
        PubSub.broadcast(topic, payload.to_json)
      end

      # Queues *payload* for this component's `handle_info`.
      def send_info(payload : String) : Nil
        @host.try(&.post(id, payload)) if connected?
      end

      # Delivers *payload* to `handle_info` once after *delay*. Cancelled when the component unmounts.
      def send_after(delay : Time::Span, payload : String) : Nil
        @host.try(&.schedule(id, delay, payload, repeat: false)) if connected?
      end

      # Delivers *payload* to `handle_info` every *interval* until the component unmounts.
      def every(interval : Time::Span, payload : String) : Nil
        @host.try(&.schedule(id, interval, payload, repeat: true)) if connected?
      end

      # Renders the child component *type* identified by *key* inside this component.
      def child(type : T.class, key : String, **props) : String forall T
        host = @host || raise Error.new("components can only be embedded while they are mounted")
        host.child(id, type, key, **props)
      end
    end
  end
end
