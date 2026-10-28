---
description: Azu reads sessions through `Azu::SessionAdapter`, which the `session` shard fills.
---

# Use sessions

Azu has no session store of its own. It reads sessions through a small seam, `Azu::SessionAdapter`, and the
[`session` shard](https://github.com/azutoolkit/session) fills it: signed and encrypted cookies (or a
memory or Redis store), session fixation protection through `authenticate`, and a flash that belongs to the
session. Azu has no dependency on the shard; you add it to your own `shard.yml`.

## Set it up

<!-- skip -->
```crystal
require "azu"
require "session/azu"

class UserSession < Session::Base
  property user_id : Int64? = nil
  property csrf_token : String? = nil

  def authenticated? : Bool
    !user_id.nil?
  end
end

Session::Web.use_store(Session::CookieStore(UserSession))

Session.configure do |config|
  config.secret = Azu::Env.secret("SESSION_SECRET")
  config.store = Session::CookieStore(UserSession).new
end
```

`Session::Web.use_store` adds the typed `context.session` and `context.flash` to `HTTP::Server::Context`.

{% hint style="warning" %}
`SESSION_SECRET` is required in production.
{% endhint %}

Put `Session::SessionHandler(UserSession).new(Session.session)` in the handler list before the router; it saves the
session just before the response starts (`Session::CommitOnWrite`), so a streamed response keeps its cookie.

## Use a connection pool for Redis

For a Redis-backed application, replace the cookie-store setup above with this alternative. A shared store
must lease a Redis connection for each operation: overlapping requests on a single unpooled connection can
consume each other's replies and fail session reads.

<!-- skip -->
```crystal
Session::Web.use_store(Session::RedisStore(UserSession))

pool = Session::ConnectionPool.new(Session::ConnectionPoolConfig.new(
  size: 20,
  timeout: 1.second,
  redis_host: ENV.fetch("REDIS_HOST", "127.0.0.1"),
  redis_port: ENV.fetch("REDIS_PORT", "6379").to_i,
  redis_database: ENV.fetch("REDIS_DATABASE", "0").to_i,
  redis_password: ENV["REDIS_PASSWORD"]?,
))
Session.configure do |config|
  config.secret = Azu::Env.secret("SESSION_SECRET")
  config.encrypt_redis_data = true
  config.cookie_secure = true
  config.store = Session::RedisStore(UserSession).with_pool(pool)
end
Azu.on_shutdown { pool.shutdown }
```

Size the pool and checkout timeout for the application's concurrency and Redis connection budget; these
values are an example. Encryption of stored session values does not encrypt the Redis connection. Provide
a protected transport/network for your deployment. A coordinated change of the encryption key invalidates
existing sessions; rolling rotation with overlapping keys needs a separate policy.

The [runnable Redis example](https://github.com/azutoolkit/azu/blob/master/playground/redis_sessions/README.md) pins the tested session revision
and includes real Redis tests for concurrent visitors, CSRF and session preservation on errors.

## Connect the template helpers and CSRF

<!-- skip -->
```crystal
Azu.session_adapter = Azu::SessionAdapter.new(
  flash: ->(context : HTTP::Server::Context) { context.flash.to_h },
  csrf_token: ->(context : HTTP::Server::Context) { context.session.csrf_token },
  store_csrf_token: ->(context : HTTP::Server::Context, token : String) {
    context.session.csrf_token = token
    nil
  },
)
```

Install the adapter once at boot, before serving: it lives on the configuration of the app
(`Azu.session_adapter=` sets it on the current one; an `Azu::App` has its own).

Without an adapter, `flash` in templates is empty. A template shows messages with `{{ flash.notice }}`.

A response's `view` gives the template `flash` and, once the app uses `Azu::Handler::CSRF`, `csrf_token` (see
[Render HTML templates](../templates/render-html-templates.md)):

```jinja
{% if flash.error %}<p class="error">{{ flash.error }}</p>{% endif %}
{{ csrf_field() }}
```

`session` is deliberately not given to templates: a session holds identifiers and tokens that a template has no
business printing. Pass what a page needs through its response object, or give the adapter's `session:` proc an
allowlist (`->(context : HTTP::Server::Context) { {"name" => context.session.name.to_s} }`) and read it as
`TemplateContext#session`. Flash values are user-influenced text; `.jinja` templates are autoescaped, so `{{ flash.notice }}` is safe.

## Render errors before releasing the session

Place an inner `Rescuer` immediately after the session handler. An endpoint exception must be rendered
while the request's session is still active: otherwise the session handler's cleanup runs first, and its
deferred cookie writer can replace the authenticated session when the outer error handler writes the 500.

<!-- skip -->
```crystal
app = Azu::App.new
app.config.session_adapter = Azu::SessionAdapter.new(
  csrf_token: ->(context : HTTP::Server::Context) { context.session.csrf_token },
  store_csrf_token: ->(context : HTTP::Server::Context, token : String) { context.session.csrf_token = token; nil },
)
csrf = Azu::Handler::CSRF.new(
  strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
  token_store: Azu::Handler::CSRF::SessionTokenStore.new,
)
app.start([
  Session::SessionHandler(UserSession).new(Session.session),
  Azu::Handler::Rescuer.new,
  csrf,
] of HTTP::Handler, defaults: true)
```

Register your routes before `start`. `defaults: true` retains the default outer error/security handlers;
the outer rescuer covers failures entering session middleware. The resulting order is outer rescuer/security
handlers → session → inner rescuer → CSRF → routes. Install the adapter on `app.config`, not the global
configuration, when using an app instance. If templates use `csrf_token`, configure/use `CSRF.default`
as described in [Built-in handlers](../../reference/handlers/built-in.md#handlercsrf).

## Use it in endpoints

<!-- skip -->
```crystal
struct Sessions::CreateEndpoint
  include Azu::Endpoint(Sessions::CreateRequest, Azu::Response::Empty)

  post "/login"

  def call : Azu::Response::Empty
    unless user = User.authenticate(create_request.email, create_request.password)
      context.flash["error"] = "Invalid email or password"
      return redirect to: "/login", status: 303
    end

    # A new session id and a new CSRF token on every privilege change: clearing the token makes the
    # next form regenerate it
    Session.session.authenticate do |session|
      session.user_id = user.id
      session.csrf_token = nil
    end
    redirect to: "/account", status: 303
  end
end
```

Use the store with `Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
token_store: Azu::Handler::CSRF::SessionTokenStore.new)`, placed **after** `Session::SessionHandler` in the
handler chain. If the session is missing or unreadable, the request is refused with 403.

{% hint style="warning" %}
`context.session` and `context.flash` work only in the request's own fiber, behind the session handler. A
WebSocket channel or a `spawn`ed fiber has no session and gets `Session::Web::MissingSession`.
{% endhint %}

## See also

- [Built-in Handlers: CSRF](../../reference/handlers/built-in.md#handlercsrf)
- the session shard's `docs/integrations/azu-framework.md`
