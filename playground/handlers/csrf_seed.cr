require "../../src/azu"

module ExampleApp
  # Gives a first-time visitor one CSRF token for the whole page.
  #
  # The template context asks the CSRF handler for a token several times while a page is
  # rendered (the `csrf_token` variable, the meta tag and the form fields). With no cookie
  # yet, each ask would mint a different token and only the last one would reach the cookie,
  # so the first form a new visitor submits would be rejected. Minting the token once, up
  # front, and presenting it as if the browser had sent it makes every ask return the same one.
  class CsrfSeed
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      name = Azu::Handler::CSRF.cookie_name
      if context.request.method == "GET" && !context.request.cookies[name]?
        token = Azu::Handler::CSRF.token(context)
        cookie = "#{name}=#{token}"
        existing = context.request.headers["Cookie"]?
        context.request.headers["Cookie"] = existing ? "#{existing}; #{cookie}" : cookie
      end
      call_next(context)
    end
  end
end
