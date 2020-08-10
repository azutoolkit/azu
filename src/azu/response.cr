module Azu
  module Response
    include Helpers
    @context = uninitialized HTTP::Server::Context
  end
end
