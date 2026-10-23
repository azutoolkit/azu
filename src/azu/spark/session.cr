require "digest/sha256"
require "json"
require "log"
require "./component"
require "./configuration"
require "./connection_info"
require "./entry"
require "./instrumentation"
require "./registry"
require "./rehydrator"
require "./token"
require "./update"

module Azu
  module Spark
    # A message for `handle_info` of component *target*, produced by PubSub subscriptions and timers.
    record Info, target : String, message : PubSub::Message

    # Topic of messages a component sends to itself.
    SELF_TOPIC = "@self"

    # All the live state of one client: its components and the work of mounting them, routing
    # events and messages to them and working out what changed in the DOM.
    #
    # A session is driven from a single fiber (the connection's processing loop, or the test
    # harness), so component code never runs concurrently. Work that happens elsewhere (PubSub
    # deliveries, timers) re-enters through the *sink* as an `Info`.
    class Session
      getter registry : Registry
      getter? connected : Bool

      def initialize(@connection : ConnectionInfo, @connected : Bool = true,
                     @config : Configuration = Spark.config, &@sink : Info ->)
        @registry = Registry.new(@connection.id, @config.max_components)
        @dirty = {} of String => Entry
        @pushes = [] of Update::Push
        @redirect = nil.as(Update::Redirect?)
        @claims = {} of String => Hash(String, String)
        @rehydrator = Rehydrator.new(@config)
        @sent_snapshots = {} of String => String
        @expanding = false
      end

      # Mounts the view of a join token and returns the initial render.
      def join(token : String, snapshot : String?, params : Params) : Update
        claims = Token.verify("join", token, @config.secret)
        root_id = claims["id"].as_s
        component = Catalog.build(claims["view"].as_s, claims["props"])
        start(component, root_id, claims["session"].as_h.transform_values(&.as_s), params, snapshot)
      end

      # Mounts *component* as the root *id* and returns its initial render. A snapshot token
      # from a previous connection restores the persisted state of its components.
      def start(component : Component, id : String, claims : Hash(String, String), params : Params, snapshot : String? = nil) : Update
        @claims[id] = claims
        @rehydrator.load(snapshot, id, claims)
        mount(component, id, nil, params)
        flush
      rescue ex
        leave(id)
        raise ex
      ensure
        @rehydrator.clear
      end

      # Mounts *component* as a root without a connection and returns it wrapped in its element,
      # as sent in the initial HTTP response. Nothing outlives the call.
      def render_page(component : Component, id : String, claims : Hash(String, String), params : Params, **attributes) : String
        @claims[id] = claims
        entry = mount(component, id, nil, params)
        wrap(entry, **attributes)
      ensure
        close
      end

      # Delivers a client event to its target component and returns the resulting changes.
      def event(target : String, name : String, payload : Params) : Update
        entry = @registry[target]
        handled = Instrumentation.measure(entry, "event_handler:#{name}") do
          entry.component.handle_event(name, payload, entry.component.socket)
        end
        raise UnknownEvent.new("#{entry.component.class.name} does not handle '#{name}'") unless handled
        @dirty[entry.id] = entry
        flush
      end

      # Delivers a PubSub or timer message; messages for components that are gone are dropped.
      def info(target : String, message : PubSub::Message) : Update
        return Update.new unless entry = @registry[target]?
        Instrumentation.measure(entry, "event_handler:info") do
          entry.component.handle_info(message, entry.component.socket)
        end
        @dirty[entry.id] = entry
        flush
      end

      # Unmounts the root *id* and everything below it.
      def leave(id : String) : Nil
        unmount_tree(id)
        @claims.delete(id)
        @sent_snapshots.delete(id)
      end

      # Unmounts everything; call exactly once when the client is gone.
      def close : Nil
        @registry.drain.sort_by { |entry| -entry.depth }.each { |entry| retire(entry) }
        @dirty.clear
      end

      # Current HTML of the component *id* with all its descendants expanded, as the browser shows it.
      def html(id : String) : String
        entry = @registry[id]
        @expanding = true
        wrap(entry)
      ensure
        @expanding = false
      end

      # :nodoc:
      def mark_dirty(id : String) : Nil
        if entry = @registry[id]?
          @dirty[id] = entry
        end
      end

      # :nodoc:
      def subscribe(id : String, topic : String) : Nil
        return unless entry = @registry[id]?
        return if entry.subscriptions.has_key?(topic)
        entry.subscriptions[topic] = PubSub.subscribe(topic) { |message| @sink.call(Info.new(id, message)) }
      end

      # :nodoc:
      def unsubscribe(id : String, topic : String) : Nil
        @registry[id]?.try(&.subscriptions.delete(topic)).try(&.cancel)
      end

      # :nodoc:
      def post(id : String, payload : String) : Nil
        @sink.call(Info.new(id, PubSub::Message.new(SELF_TOPIC, payload)))
      end

      # :nodoc:
      def schedule(id : String, interval : Time::Span, payload : String, repeat : Bool) : Nil
        return unless entry = @registry[id]?
        Azu.spawn_scoped("azu-spark-timer") do
          loop do
            select
            when entry.retired.receive?
              break
            when timeout(interval)
              post(id, payload)
              break unless repeat
            end
          end
        end
      end

      # :nodoc:
      def push_event(id : String, name : String, payload : JSON::Any) : Nil
        @pushes << Update::Push.new(id, name, payload)
      end

      # :nodoc:
      def redirect(to : String, replace : Bool) : Nil
        @redirect = Update::Redirect.new(to, replace)
      end

      # :nodoc:
      def child(parent_id : String, type : T.class, key : String, **props) : String forall T
        parent = @registry[parent_id]
        raise BadRequest.new("child key must not be empty") if key.empty?
        entry = child_entry(parent, type, "#{parent_id}~#{key}", **props)
        parent.children << entry.id
        @connected && !@expanding ? placeholder(entry) : wrap(entry)
      end

      private def child_entry(parent : Entry, type : T.class, id : String, **props) : Entry forall T
        if (existing = @registry[id]?) && (component = existing.component.as?(T))
          @dirty[id] = existing if component.__spark_assign_props(**props)
          return existing
        end
        unmount_tree(id) if existing
        mount(type.new(**props), id, parent, Params.new)
      end

      private def mount(component : Component, id : String, parent : Entry?, params : Params) : Entry
        root_id = parent.try(&.root_id) || id
        entry = Entry.new(component, id, parent.try(&.id), root_id, (parent.try(&.depth) || -1) + 1)
        socket = Socket.new(id, entry.parent_id, self, @connection, @claims[root_id]? || {} of String => String, @connected)
        component.__spark_attach(socket)
        @registry.add(entry)
        begin
          Instrumentation.measure(entry, "mount") { component.mount(socket, params) }
          @rehydrator.restore(component, id)
        rescue ex
          @registry.delete(id)
          entry.retire
          raise ex
        end
        @dirty[id] = entry
        entry
      end

      private def unmount_tree(id : String) : Nil
        return unless entry = @registry.delete(id)
        entry.children.each { |child_id| unmount_tree(child_id) }
        retire(entry)
      end

      private def retire(entry : Entry) : Nil
        @dirty.delete(entry.id)
        entry.retire
        Instrumentation.measure(entry, "unmount") { entry.component.unmount(entry.component.socket) }
      rescue ex
        Log.for("Azu::Spark").error(exception: ex) { "#{entry.component.class.name} failed to unmount" }
      end

      # Renders everything that changed, parents before children.
      private def flush : Update
        patches = [] of Update::Patch
        touched = Set(String).new
        limit = @config.max_components * 4
        while entry = @dirty.values.min_by?(&.depth)
          raise Error.new("render loop: components keep changing state while rendering") if (limit -= 1) < 0
          @dirty.delete(entry.id)
          touched << entry.root_id
          render(entry).try { |patch| patches << patch }
        end
        update = Update.new(patches, @pushes.dup, @redirect, snapshots(touched))
        @pushes.clear
        @redirect = nil
        update
      end

      private def render(entry : Entry) : Update::Patch?
        html = render_inner(entry)
        digest = Digest::SHA256.hexdigest(html)
        return if digest == entry.digest
        entry.digest = digest
        Update::Patch.new(entry.id, html)
      end

      # Runs `render`, then unmounts the children it no longer embeds.
      private def render_inner(entry : Entry) : String
        previous = entry.children
        entry.children = Set(String).new
        html = Instrumentation.measure(entry, "refresh") { entry.component.__spark_render }
        (previous - entry.children).each { |child_id| unmount_tree(child_id) }
        html
      rescue ex
        entry.children = previous if previous
        raise ex
      end

      private def wrap(entry : Entry, **attributes) : String
        component = entry.component
        "#{component.__spark_open(**attributes)}#{render_inner(entry)}#{component.__spark_close}"
      end

      private def placeholder(entry : Entry) : String
        component = entry.component
        "#{component.__spark_open("data-spark-slot": nil)}#{component.__spark_close}"
      end

      # Signed snapshots for the roots rendered in this flush whose persisted state changed.
      private def snapshots(roots : Set(String)) : Hash(String, String)
        roots.each_with_object({} of String => String) do |root_id, tokens|
          next unless token = snapshot_token(root_id)
          tokens[root_id] = token
        end
      end

      private def snapshot_token(root_id : String) : String?
        members = {} of String => Snapshot::Member
        @registry.entries.each do |entry|
          next unless entry.root_id == root_id
          entry.component.__spark_snapshot.try { |state| members[entry.id] = Snapshot::Member.new(entry.component.class.name, state) }
        end
        return if members.empty?

        encoded = members.to_json
        return if @sent_snapshots[root_id]? == encoded
        token = Snapshot.sign(root_id, @claims[root_id]? || {} of String => String, members, @config.token_ttl, @config.secret, @config.max_snapshot_size)
        unless token
          Log.for("Azu::Spark").warn { "Persisted state of #{root_id} exceeds #{@config.max_snapshot_size} bytes and was not saved" }
          return
        end
        @sent_snapshots[root_id] = encoded
        token
      end
    end
  end
end
