require "json"

module Azu
  module Spark
    # What the client must apply after the server handled one input: DOM patches, events to
    # dispatch in the browser, an optional navigation and refreshed state snapshots.
    record Update,
      patches : Array(Update::Patch) = [] of Update::Patch,
      pushes : Array(Update::Push) = [] of Update::Push,
      redirect : Update::Redirect? = nil,
      snapshots : Hash(String, String) = {} of String => String do
      # New inner HTML of the component *id*.
      record Patch, id : String, html : String

      # A server initiated browser event (`Socket#push_event`).
      record Push, target : String, name : String, payload : JSON::Any

      record Redirect, to : String, replace : Bool

      def empty? : Bool
        patches.empty? && pushes.empty? && redirect.nil? && snapshots.empty?
      end
    end
  end
end
