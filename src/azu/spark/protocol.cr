require "json"
require "./update"

module Azu
  module Spark
    # The wire format: one JSON object per WebSocket text frame, `{"v": 1, "type": ..., ...}`.
    #
    # Client to server
    # - `join`      `id`, `token`, optional `snapshot` and `params` (the page's query string). The
    #               `snapshot` is the latest signed state of the page (see `Snapshot`): after a
    #               reconnect the server mounts the components from it, so the page continues
    #               where it was. A bad snapshot answers `invalid_snapshot` and mounts nothing.
    # - `event`     `id`, `target` (component id), `event`, `payload`, and optionally `eid` (the
    #               client's event number, see Delivery below) and `gen` (the generation of the
    #               root the user acted on, from the reply to its join)
    # - `heartbeat` `id`
    # - `leave`     `target` (root component id)
    #
    # Server to client
    # - `hello`     `heartbeat` and `max_size`, sent on connect
    # - `diff`      `seq`, `patches` (`id`, `html`), `events` (`target`, `name`, `payload`), `snapshots`,
    #               and `ack` when the diff answers a numbered event
    # - `reply`     `id`, `target`; acknowledges a request, sent after the diff it caused. Optional:
    #               `gen` (in the reply to a join of a root that persists state), `ack`, and `dup`
    #               (the event had been applied before: nothing was done)
    # - `redirect`  `to`, `replace`
    # - `heartbeat` `id`
    # - `error`     `code`, `message`, and the `id` of the request it answers (null otherwise); `ack`
    #               when it answers a numbered event
    #
    # Error codes: `invalid_token` (the page can never join), `invalid_snapshot` (join again
    # without the snapshot), `rejected`, `bad_request`, `unknown_target`, `unknown_event`,
    # `stale_event` (the event belongs to an earlier incarnation of the page: drop it),
    # `limit_exceeded`, `rate_limited` and `internal`.
    #
    # Client ids increase per connection and are echoed in the matching reply, which is how the
    # browser clears loading states and detects lost requests. `seq` orders server pushes.
    #
    # Delivery. A client that numbers its events (`eid`, increasing per page, kept across
    # reconnects) resends the ones nobody acknowledged after a reconnect, which always means on a NEW
    # connection. The server keeps, per connection and root, the highest `eid` it has taken: an event
    # at or below it is not applied again (the reply says `dup`). That protects against a repeat on
    # the same connection (a buggy or replaying client, a proxy). It does not carry over to a new
    # connection, on purpose: the page is mounted from the snapshot the client holds, and a resent
    # event that the old connection handled is applied to that state, which is what keeps the state
    # of the components exactly-once. `gen` keeps events of an older page from being applied to a
    # page mounted afresh. `ack` carries the `eid` of the event a frame answers; a numbered event
    # refused for rate limiting is answered the same way (`id` and `ack` in the error).
    # All of these fields are optional in both directions; a peer that does not know them ignores
    # them, and a client that sends no `eid` gets the behaviour of protocol v1 exactly.
    module Protocol
      VERSION = 1

      struct Inbound
        include JSON::Serializable

        getter v : Int32 = VERSION
        getter type : String
        getter id : Int64? = nil
        getter target : String? = nil
        getter event : String? = nil
        getter payload : Hash(String, JSON::Any)? = nil
        getter eid : Int64? = nil
        getter gen : String? = nil
        getter token : String? = nil
        getter snapshot : String? = nil
        getter params : Hash(String, String)? = nil
      end

      def self.hello(heartbeat : Time::Span, max_size : Int32) : String
        frame("hello") do |json|
          json.field "heartbeat", heartbeat.total_milliseconds.to_i
          json.field "max_size", max_size
        end
      end

      def self.diff(seq : Int64, update : Update, ack : Int64? = nil) : String
        frame("diff") do |json|
          json.field "seq", seq
          json.field "ack", ack if ack
          json.field "patches" do
            json.array do
              update.patches.each do |patch|
                json.object do
                  json.field "id", patch.id
                  json.field "html", patch.html
                end
              end
            end
          end
          json.field "events" do
            json.array do
              update.pushes.each do |push|
                json.object do
                  json.field "target", push.target
                  json.field "name", push.name
                  json.field "payload", push.payload
                end
              end
            end
          end
          json.field "snapshots", update.snapshots
        end
      end

      def self.redirect(redirect : Update::Redirect) : String
        frame("redirect") do |json|
          json.field "to", redirect.to
          json.field "replace", redirect.replace
        end
      end

      def self.reply(id : Int64?, target : String? = nil, gen : String? = nil, ack : Int64? = nil, dup : Bool = false) : String
        frame("reply") do |json|
          json.field "id", id
          json.field "target", target if target
          json.field "gen", gen if gen
          json.field "ack", ack if ack
          json.field "dup", true if dup
        end
      end

      def self.error(id : Int64?, code : String, message : String, ack : Int64? = nil) : String
        frame("error") do |json|
          json.field "id", id
          json.field "code", code
          json.field "message", message
          json.field "ack", ack if ack
        end
      end

      def self.heartbeat(id : Int64?) : String
        frame("heartbeat") { |json| json.field "id", id }
      end

      private def self.frame(type : String, & : JSON::Builder ->) : String
        JSON.build do |json|
          json.object do
            json.field "v", VERSION
            json.field "type", type
            yield json
          end
        end
      end
    end
  end
end
