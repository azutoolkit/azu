require "../../azu"
require "./cookie_jar"
require "./response"
require "./sessions"
require "./web_socket"
require "./client"

module Azu
  # In-process testing of an app: `Azu::Testing::Client` (HTTP through the real router and handler chain),
  # `Azu::Testing::WebSocket` (channels) and the Spark helpers. Opt in with `require "azu/testing"`;
  # `require "azu"` does not load it. See docs/reference/api/testing.md.
  module Testing
    # Mounts a live component for a test; see `Azu::Spark::Testing`.
    def self.mount(type : T.class, *, session : Hash(String, String) = {} of String => String,
                   params : Hash(String, String) = {} of String => String, snapshot : String? = nil, **props, &) forall T
      Spark::Testing.mount(type, **props, session: session, params: params, snapshot: snapshot) { |view| yield view }
    end
  end
end
