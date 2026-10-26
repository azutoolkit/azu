require "http/headers"

module Azu
  module Handler
    # :nodoc:
    #
    # Header writes for values already known to be valid, without `HTTP::Headers#[]=` checking every byte of the
    # value again or wrapping the name on each call. SecurityHeaders checks its values once, when it is built; RequestId
    # writes an id it generated, or the client's once `HTTP::Headers#valid_value?` accepted it.
    #
    # It depends on two stdlib internals: the `:nodoc:` `HTTP::Headers::Key`, and `HTTP::Headers` passing a call it
    # does not define (`[]=` with a `Key`) to its hash through `forward_missing_to @hash`. If either changes, this
    # stops compiling; the public fallback is `headers.has_key?(name)` plus `headers[name] = value`, which checks the
    # value and hashes the name on every call.
    module TrustedHeader
      # The name as `HTTP::Headers` keys it, built once.
      def self.key(name : String) : HTTP::Headers::Key
        HTTP::Headers::Key.new(name)
      end

      # Sets *key* to *value*, replacing a value under any spelling of the name. *value* must be valid already.
      def self.set(headers : HTTP::Headers, key : HTTP::Headers::Key, value : String) : Nil
        headers[key] = value
      end
    end
  end
end
