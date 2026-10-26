---
description: "Serve a second Azu::App below a path of your app, link into it, guard it with middleware and test it."
---

# Mount an app under a prefix

`mount` hands every request below a path to another `Azu::App`. The mounted app keeps its own routes and
configuration; the app that owns the server keeps the handler chain, and the mounted app is not started. The
examples build an admin app and serve it at `/admin`.

## Build the app to mount

Declare the mounted app's routes in its `routes` block. A verb macro in an endpoint body (`get "/users"`) also
registers the route on `Azu::App.default`, the app of the `include Azu` facade, where it answers without the prefix
and outside any middleware you put on the mount (see [Router](../../reference/api/router.md#verb-macros)).

<!-- prelude -->
```crystal
require "azu"

module Admin
  struct UsersPage
    include Azu::Response

    def render
      %({"users":["ada","grace"],"self":"#{UsersEndpoint.path}"})
    end
  end

  struct UsersEndpoint
    include Azu::Endpoint(Azu::Request, UsersPage)

    def call : UsersPage
      content_type "application/json"
      UsersPage.new
    end
  end

  class LiveChannel < Azu::Channel
    def on_connect
      send "connected"
    end

    def on_message(message : String)
      send message.upcase
    end

    def on_binary(binary : Bytes)
    end

    def on_ping(message : String)
    end

    def on_pong(message : String)
    end

    def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    end
  end

  # One app per mount: an app can be mounted once.
  def self.app : Azu::App
    app = Azu::App.new
    app.routes do
      get "/users", UsersEndpoint
      ws "/live", LiveChannel
    end
    app
  end
end
```

## Mount it

```crystal
site = Azu::App.new
site.routes do
  mount Admin.app, at: "/admin"
end

site.start
```

`GET /admin/users` now runs `Admin::UsersEndpoint`. While the admin app serves a request:

- the path has the prefix removed (`/admin/users` is `/users`, `/admin` is `/`); the query string is unchanged;
- `Azu.current_config` is the admin app's configuration: its templates, cache, log, upload and WebSocket settings
  and `error_format`;
- `Azu.current_app` is still `site`, so the request counts as one of `site`'s and is refused with `503` once `site`
  shuts down.

The path must start with `/` and name a sub path: `at: "/"` and `at: "admin"` raise `ArgumentError`, and a
trailing slash is dropped. Mounting the same app a second time raises `ArgumentError` ("app is already mounted
at /admin; build one app per mount"). Mounts nest, and the prefixes add up.

With the `include Azu` facade the app that owns the server is `Azu::App.default`: call
`Azu::App.default.routes { mount Admin.app, at: "/admin" }` before `MyApp.start`.

## Link into the mounted app

Inside the admin app, `Endpoint.path` includes the prefix, so `Admin::UsersEndpoint.path` is `/admin/users` and
the response above carries `"self":"/admin/users"`. `Azu.mounted_path(Admin::UsersEndpoint)` returns the same.

Outside it, in an endpoint or template of `site`, the current router does not route the admin endpoints, and
`Endpoint.path` falls back to the path the type declared with a verb macro (none here, so `""`). Keep the admin
app and ask with its configuration current:

```crystal
admin = Admin.app
site = Azu::App.new
site.routes { mount admin, at: "/admin" }

Azu.with_config(admin.config) { Admin::UsersEndpoint.path } # => "/admin/users"
```

{% hint style="info" %}
What a mounted app reads from the request has no prefix: in its templates `current_path` is `/users` and
`current_url` ends in `/users`, and a `404` its router answers names `/nope` for `/admin/nope`. Build links with
`Endpoint.path`.
{% endhint %}

## Guard one mount with middleware

The handlers passed to `start` belong to `site` and run for every request, mounted or not. The admin app's own
handlers never run, because it is not started. To put middleware on the mount only, add a handler to `site`'s
chain that checks the path:

<!-- prelude -->
```crystal
require "crypto/subtle"

class AdminGate
  include HTTP::Handler

  def initialize(@prefix : String, @token : String)
  end

  def call(context : HTTP::Server::Context)
    path = context.request.path
    return call_next(context) unless path == @prefix || path.starts_with?("#{@prefix}/")
    return call_next(context) if authorized?(context.request)

    context.response.status = :unauthorized
    context.response.headers["WWW-Authenticate"] = "Bearer"
  end

  private def authorized?(request : HTTP::Request) : Bool
    given = request.headers["Authorization"]?.try(&.lchop?("Bearer ")) || return false
    Crypto::Subtle.constant_time_compare(given, @token)
  end
end
```

```crystal
site = Azu::App.new
site.routes { mount Admin.app, at: "/admin" }

site.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  AdminGate.new("/admin", Azu::Env.secret("ADMIN_TOKEN")),
  Azu::Handler::SecurityHeaders.new,
  Azu::Handler::Static.new(fallthrough: true),
] of HTTP::Handler
```

`GET /admin/users` without the token answers `401`; with `Authorization: Bearer <ADMIN_TOKEN>` it answers `200`.
Paths outside `/admin` pass. Compare on `request.path`, whole segments and case-sensitively, as the router does:
`/administrator` is not under `/admin`, and `/Admin/users` reaches no route. WebSocket upgrades below `/admin` pass
through the gate too.

## Templates and WebSockets in the mounted app

- **Templates.** `admin.config.templates.path = "src/admin/templates"` adds a directory to the admin app's search
  path, and a response rendered while the admin app serves (`view`) reads from it. `site.start` compiles only
  `site`'s templates; call `admin.prepare` before it, so a template of the admin app that does not parse stops the
  boot instead of failing its first render.
- **i18n.** Starting `site` applies `site`'s `config.i18n` to the one translation table of the process; the admin
  app's i18n settings are not applied.
- **WebSockets.** `ws "/live", Admin::LiveChannel` in the admin app's `routes` answers at `/admin/live`. The channel
  reads the admin app's WebSocket settings (`allowed_origins`, `max_message_size`), and the socket belongs to `site`,
  which closes it with `1001` when it shuts down. A class-level `ws "/live"` inside the channel registers on
  `Azu::App.default`, not on the admin app.

## Test it

`Azu::Testing::Client.new(site, handlers)` drives `site`'s chain and router in process, mounts included:

```crystal
require "spec"
require "azu/testing"

describe "the admin mount" do
  it "serves the admin app below /admin, behind the gate" do
    site = Azu::App.new
    site.routes { mount Admin.app, at: "/admin" }
    handlers = [
      Azu::Handler::RequestId.new,
      Azu::Handler::Rescuer.new,
      AdminGate.new("/admin", "s3cret"),
    ] of HTTP::Handler
    client = Azu::Testing::Client.new(site, handlers)

    client.get("/admin/users").status_code.should eq 401

    client.headers["Authorization"] = "Bearer s3cret"
    response = client.get("/admin/users")
    response.status_code.should eq 200
    response.json["self"].should eq "/admin/users"

    socket = client.connect("/admin/live")
    socket.receive.should eq "connected"
    socket.send("hi")
    socket.receive.should eq "HI"
    socket.close
  end
end
```

## See also

- [App](../../reference/api/app.md): `mount`, `prepare` and the handler chain
- [Router](../../reference/api/router.md#mounting-another-app): what a mount registers and how paths are matched
- [Apps, configuration and scope](../../explanation/architecture/apps-and-scope.md)
- [Testing](../../reference/api/testing.md)
