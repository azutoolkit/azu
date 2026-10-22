require "./session"

module Azu
  module Spark
    # Unit testing of components without a WebSocket: the component is driven by a real
    # `Session`, so mounting, event dispatch, `handle_info`, child components and change
    # detection behave exactly as they do in production.
    #
    # ```
    # Azu::Spark::Testing.mount(CounterView, label: "Clicks") do |view|
    #   view.trigger("increment")
    #   view.html.should contain("Clicks: 1")
    #   view.assigns[:count].should eq 1
    # end
    # ```
    module Testing
      ROOT_ID = "root"

      # Mounts *type* and yields a `View`, unmounting it afterwards.
      def self.mount(type : T.class, *, session : Hash(String, String) = {} of String => String,
                     params : Hash(String, String) = {} of String => String,
                     snapshot : String? = nil, **props, &) forall T
        view = mount(type, **props, session: session, params: params, snapshot: snapshot)
        yield view
      ensure
        view.try(&.close)
      end

      # Mounts *type* and returns a `View`; call `close` when done to release PubSub subscriptions.
      def self.mount(type : T.class, *, session : Hash(String, String) = {} of String => String,
                     params : Hash(String, String) = {} of String => String,
                     snapshot : String? = nil, **props) : View(T) forall T
        View(T).new(T.new(**props), session, Params.from_strings(params), snapshot)
      end

      class View(T)
        getter component : T
        getter session : Session
        # Everything pushed to the browser so far.
        getter patches = [] of Update::Patch
        getter pushes = [] of Update::Push
        getter redirect : Update::Redirect? = nil
        # The latest signed state snapshot, to hand to a later `Testing.mount(..., snapshot:)`.
        getter snapshot : String? = nil

        def initialize(@component : T, claims : Hash(String, String), params : Params, snapshot : String?)
          @inbox = [] of Info
          @session = Session.new(ConnectionInfo.detached, true) { |info| @inbox << info }
          apply(@session.start(@component, ROOT_ID, claims, params, snapshot))
          settle
        end

        # HTML of the whole component tree, children expanded, as the browser would show it.
        def html : String
          @session.html(ROOT_ID)
        end

        def assigns
          component.assigns
        end

        # Sends the client event *event* to *target* (the root by default).
        def trigger(event : String, payload : Hash(String, JSON::Any) = {} of String => JSON::Any, target : Component = component) : self
          apply(@session.event(target.id, event, Params.new(payload)))
          settle
          self
        end

        def trigger(event : String, target : Component = component, **payload) : self
          trigger(event, JSON.parse(payload.to_json).as_h, target)
        end

        # Sends *payload* to the root's `handle_info`.
        def send_info(payload : String) : self
          component.socket.send_info(payload)
          settle
          self
        end

        # Broadcasts on PubSub and processes the deliveries to this view.
        def broadcast(topic : String, payload : String) : self
          PubSub.broadcast(topic, payload)
          settle
          self
        end

        # Processes messages that arrived since the last call, after waiting *wait* for timers.
        def settle(wait : Time::Span = Time::Span.zero) : self
          sleep wait if wait > Time::Span.zero
          while info = @inbox.shift?
            apply(@session.info(info.target, info.message))
          end
          self
        end

        # The mounted components of class *type*, descendants included.
        def components(type : C.class) : Array(C) forall C
          @session.registry.entries.compact_map(&.component.as?(C))
        end

        def close : Nil
          @session.close
        end

        private def apply(update : Update) : Nil
          @patches.concat(update.patches)
          @pushes.concat(update.pushes)
          @redirect = update.redirect || @redirect
          @snapshot = update.snapshots[ROOT_ID]? || @snapshot
        end
      end
    end
  end
end
