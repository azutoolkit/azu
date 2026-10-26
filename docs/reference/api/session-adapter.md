---
description: "The seam through which templates, the CSRF session token store and the test client reach your session library."
---

# Session adapter

`Azu::SessionAdapter` tells Azu how to read the session of a request. Azu has no session store and no dependency on
a session library: an app that uses one (the `session` shard, see [Use sessions](../../how-to/middleware/use-sessions.md))
installs an adapter at boot, and the template variable `flash`, `Helpers::TemplateContext#session` and
`Handler::CSRF::SessionTokenStore` read through it. It comes with `require "azu"`. Without an adapter, sessions and
flash read as empty.

```crystal
require "azu"

class AppSession
  property csrf_token : String? = nil
  property flash = {} of String => String
end

# One session per visitor, found from the request (a real app asks its session library)
sessions = Hash(String, AppSession).new { |hash, id| hash[id] = AppSession.new }
session_of = ->(context : HTTP::Server::Context) { sessions[context.request.headers["X-Session-Id"]? || ""] }

Azu.session_adapter = Azu::SessionAdapter.new(
  flash: ->(context : HTTP::Server::Context) { session_of.call(context).flash },
  csrf_token: ->(context : HTTP::Server::Context) { session_of.call(context).csrf_token },
  store_csrf_token: ->(context : HTTP::Server::Context, token : String) { session_of.call(context).csrf_token = token; nil },
)
```

## API

`Azu::SessionAdapter.new(session:, flash:, csrf_token:, store_csrf_token:)`, every argument optional:

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `session` | `Proc(HTTP::Server::Context, Values)?` | `nil` | The session values a template may see (`TemplateContext#session`) |
| `flash` | `Proc(HTTP::Server::Context, Values)?` | `nil` | The flash messages: the `flash` template variable |
| `csrf_token` | `Proc(HTTP::Server::Context, String?)?` | `nil` | Reads the CSRF token kept in the session |
| `store_csrf_token` | `Proc(HTTP::Server::Context, String, Nil)?` | `nil` | Keeps a new CSRF token in the session |

`Values` is `Hash(String, String)`. `csrf_token` and `store_csrf_token` go together: giving one without the other
raises `ArgumentError` (`csrf_token and store_csrf_token must be given together`), because a token that can be read
but never stored, or the reverse, would make every request fail validation without saying why.

| Method | Returns | Notes |
| --- | --- | --- |
| `csrf?` | `Bool` | True when the CSRF procs were given |
| `session(context)` | `Values` | The `session` proc's answer, an empty hash without one |
| `flash(context)` | `Values` | The `flash` proc's answer, an empty hash without one |
| `csrf_token(context)` | `String?` | The stored token, `nil` without the procs |
| `store_csrf_token(context, token)` | `Nil` | Does nothing without the procs |
| `Azu.session_adapter` | `SessionAdapter?` | The adapter of the current configuration |
| `Azu.session_adapter=(adapter : SessionAdapter?)` | `SessionAdapter?` | Sets it on the current configuration |

The adapter is the [`session_adapter` option](../configuration/options.md#sessions) of a configuration, so
each `Azu::App` has its own (`app.config.session_adapter = ...`). `Azu.session_adapter` reads the configuration of
the app serving the request (`Azu.current_config`), and at boot, outside a request, the global `Azu::CONFIG`. Set it
once, before serving.

## Behavior

- The procs run in the fiber serving the request, when a template or the CSRF handler asks. Put your session
  handler before `Handler::CSRF` and before the endpoints that render templates.
- `Handler::CSRF::SessionTokenStore` needs an adapter with `csrf?`. Issuing a token without one raises
  `Azu::SessionAdapter::NotConfigured`; a read that fails is logged and counts as no token, so the request is refused
  with `403`. Set the store on `Azu::Handler::CSRF.default`, the instance templates take their token from (see
  [Built-in handlers](../handlers/built-in.md#handlercsrf)).
- The procs must answer with the session of *that request*: one shared session object would give every visitor the
  same flash and CSRF token.
- `session` is not a template variable. Give the `session` proc an allowlist of what pages may read.
- `Azu::Testing::Client#login_with` installs an in-memory adapter on the app (see [Testing](testing.md#sessions-and-csrf)),
  and refuses an app that already has one.

## Limits

- There is no store, cookie or expiry here; those belong to the session library.
- A WebSocket channel or a fiber spawned from a request has whatever the library gives outside the request's fiber;
  the `session` shard raises there.

## See also

- [Use sessions](../../how-to/middleware/use-sessions.md)
- [Built-in handlers: CSRF](../handlers/built-in.md#handlercsrf)
- [Template helpers: request variables](../templates/helpers.md#request-variables)
