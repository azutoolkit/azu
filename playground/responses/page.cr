require "../../src/azu"

module ExampleApp
  # Flash messages travel in the `_flash` cookie (Base64 JSON), which the framework's
  # template context already reads into the `flash` variable.
  module Flash
    COOKIE = "_flash"

    def self.set(context : HTTP::Server::Context, notice : String? = nil, alert : String? = nil) : Nil
      message = Hash(String, String).new
      message["notice"] = notice if notice
      message["alert"] = alert if alert
      context.response.cookies << HTTP::Cookie.new(
        COOKIE, Base64.urlsafe_encode(message.to_json),
        path: "/", max_age: 1.minute, http_only: true, samesite: HTTP::Cookie::SameSite::Lax
      )
    end

    # A flash is shown once: expire the cookie as soon as a page has rendered it.
    def self.clear(context : HTTP::Server::Context) : Nil
      return unless context.request.cookies[COOKIE]?
      context.response.cookies << HTTP::Cookie.new(COOKIE, "", path: "/", max_age: 0.seconds, http_only: true)
    end
  end

  # One response for every HTML page: renders a template inside the shared layout with the
  # request context (CSRF token, flash, current path). A Page without a template is an empty
  # body, used by redirects.
  struct Page
    include Azu::Response
    include Azu::Templates::Renderable

    DASHBOARD = {{ env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) }}

    def self.empty : Page
      new(nil, nil)
    end

    def initialize(@template : String?, @context : HTTP::Server::Context?, @section : String = "", **data)
      @data = Hash(String, Crinja::Value).new
      data.each { |key, value| @data[key.to_s] = Crinja::Value.new(value) }
    end

    def render : String
      template = @template
      return "" unless template
      @data["section"] = Crinja::Value.new(@section)
      @data["dev_dashboard"] = Crinja::Value.new(DASHBOARD)
      if context = @context
        Flash.clear(context)
        view_with_context(template, context, @data)
      else
        view(template, @data)
      end
    end
  end
end
