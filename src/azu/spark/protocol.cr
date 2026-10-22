require "json"
require "./update"

module Azu
  module Spark
    # The wire format: one JSON object per WebSocket text frame, `{"v": 1, "type": ..., ...}`.
    #
    # Client to server
    # - `join`      `id`, `token`, optional `snapshot` and `params` (the page's query string)
    # - `event`     `id`, `target` (component id), `event`, `payload`
    # - `heartbeat` `id`
    # - `leave`     `target` (root component id)
    #
    # Server to client
    # - `hello`     `heartbeat` and `max_size`, sent on connect
    # - `diff`      `seq`, `patches` (`id`, `html`), `events` (`target`, `name`, `payload`), `snapshots`
    # - `reply`     `id`, `target`; acknowledges a request, sent after the diff it caused
    # - `redirect`  `to`, `replace`
    # - `heartbeat` `id`
    # - `error`     `code`, `message`, and the `id` of the request it answers (null otherwise)
    #
    # Client ids increase per connection and are echoed in the matching reply, which is how the
    # browser clears loading states and detects lost requests. `seq` orders server pushes.
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

      def self.diff(seq : Int64, update : Update) : String
        frame("diff") do |json|
          json.field "seq", seq
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

      def self.reply(id : Int64?, target : String? = nil) : String
        frame("reply") do |json|
          json.field "id", id
          json.field "target", target if target
        end
      end

      def self.error(id : Int64?, code : String, message : String) : String
        frame("error") do |json|
          json.field "id", id
          json.field "code", code
          json.field "message", message
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
