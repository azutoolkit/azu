require "../../src/azu"
require "../requests/empty_request"
require "../responses/page"

module ExampleApp
  struct HomeEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/"

    def call : Page
      content_type "text/html"
      people = DATABASE.scalar("SELECT COUNT(*) FROM users").as(Int64)
      posts = DATABASE.scalar("SELECT COUNT(*) FROM posts").as(Int64)
      Page.new(
        "home.html", context, "home",
        people: people, posts: posts, online: ExampleChannel.online
      )
    end
  end

  struct RealtimeEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/realtime"

    def call : Page
      content_type "text/html"
      Page.new("realtime.html", context, "realtime")
    end
  end

  struct ApiEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/api"

    ROUTES = [
      {method: "GET", path: "/text/", note: "Plain text with a 201 status", href: "/text/"},
      {method: "GET", path: "/real-db?query=all_users", note: "Rows straight from SQLite as JSON", href: "/real-db?query=all_users"},
      {method: "GET", path: "/real-db?query=n_plus_one", note: "Spot the N+1 pattern in the logs", href: "/real-db?query=n_plus_one"},
      {method: "GET", path: "/stats/cache", note: "Cache hit and miss statistics", href: "/stats/cache"},
      {method: "GET", path: "/cached/:key", note: "A deliberately slow call (5 s), then served from cache", href: "/cached/demo"},
      {method: "GET", path: "/error-demo?error_type=validation", note: "Structured error responses", href: "/error-demo?error_type=validation"},
      {method: "GET", path: "/dev-tools", note: "Generate data for the dev dashboard", href: "/dev-tools"},
      {method: "POST", path: "/json/:id", note: "Typed JSON body with validation", href: ""},
      {method: "POST", path: "/counter/:action/:key", note: "Increment, decrement or reset a counter", href: ""},
      {method: "DELETE", path: "/cache/:action", note: "Clear the cache or delete a key", href: ""},
    ]

    def call : Page
      content_type "text/html"
      Page.new("api.html", context, "api", routes: ROUTES)
    end
  end

  struct ErrorsEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/errors"

    KINDS = [
      {type: "validation", status: 422, title: "Validation", note: "Field-level messages, like a rejected form."},
      {type: "authentication", status: 401, title: "Authentication", note: "Missing or invalid credentials."},
      {type: "authorization", status: 403, title: "Authorization", note: "Signed in, but not allowed."},
      {type: "rate_limit", status: 429, title: "Rate limit", note: "Too many requests, with a retry hint."},
      {type: "database", status: 500, title: "Database", note: "A query or connection failed."},
      {type: "external_service", status: 502, title: "External service", note: "A dependency is down."},
      {type: "timeout", status: 504, title: "Timeout", note: "Something took too long."},
      {type: "generic", status: 500, title: "Unexpected", note: "An unhandled exception. Development shows the exception page."},
      {type: "missing_record", status: 500, title: "Missing record", note: "A nil where the code expected a value: the exception page names the line and the likely cause."},
    ]

    def call : Page
      content_type "text/html"
      Page.new("errors.html", context, "errors", kinds: KINDS)
    end
  end
end
