# Use Sessions

Azu has no session store of its own. It reads sessions through a small seam, `Azu::SessionAdapter`, and the
[`session` shard](https://github.com/azutoolkit/session) fills it: signed and encrypted cookies (or a
memory or Redis store), session fixation protection through `authenticate`, and a flash that belongs to the
session. Azu has no dependency on the shard; you add it to your own `shard.yml`.

The snippets below need the `session` shard, which the docs check does not install, so their blocks are marked
`<!-- skip -->`; `reference/handlers/built-in.md` has the part that needs no shard.

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
`SESSION_SECRET` is required in production. Put `Session::SessionHandler(UserSession).new(Session.session)`
in the handler list before the router; it saves the session just before the response starts
(`Session::CommitOnWrite`), so a streamed response keeps its cookie.

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

Without an adapter, `flash` in templates is empty. Azu no longer reads a `_session` or `_flash` cookie: any
client can write one, and nothing signed it. A template shows messages with `{{ flash.notice }}` as before.

`session` is deliberately not given to templates: a session holds identifiers and tokens that a template has no
business printing. Pass what a page needs through its response object, or give the adapter's `session:` proc an
allowlist (`->(context : HTTP::Server::Context) { {"name" => context.session.name.to_s} }`) and read it as
`TemplateContext#session`. Flash values are user-influenced text; `.jinja` templates are autoescaped, so `{{ flash.notice }}` is safe.

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

`context.session` and `context.flash` work only in the request's own fiber, behind the session handler. A
WebSocket channel or a `spawn`ed fiber has no session and gets `Session::Web::MissingSession`.

## See also

- [Built-in Handlers: CSRF](../../reference/handlers/built-in.md#handlercsrf)
- the session shard's `docs/integrations/azu-framework.md`
