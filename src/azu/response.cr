module Azu
  # A response is a message sent from a server to a client
  #
  # Azu:Response represents an interface for all Azu server responses. You can
  # still use Crystal `HTTP::Response` class to generete response messages.
  #
  # The response #status and #headers must be configured before writing the response body.
  # Once response output is written, changing the #status and #headers properties has no effect.
  #
  # The methods available are define in the `Helpers` class.
  module Response
  end
end
