---
description: Add CSRF protection to forms and JavaScript calls, CORS to an API, a rate limit to the login, and the headers that matter behind a proxy.
---

# Protect forms and APIs

Each protection is a handler in the array you pass to `start`. The sections below add them one at a time; the last
section puts the chain together.

Before you start: an app whose pages render templates with `view` (see
[Render HTML templates](../templates/render-html-templates.md)).

## Protect HTML forms with CSRF

Set `CSRF_SECRET` to a long random value (`openssl rand -hex 32`) in the environment of every instance.
`Azu::Handler::CSRF` signs its tokens with it; without it, a production app refuses to boot (see
[CSRF](../../reference/handlers/built-in.md#handlercsrf)).

Add `Azu::Handler::CSRF.new` to the handlers, after `Rescuer` (the whole chain is at the
[end of this page](#put-the-chain-together)). From then on, a `POST`, `PUT`, `PATCH` or `DELETE` must carry the token
of the visitor's `csrf_token` cookie. Put `csrf_field()` in every form:

{% code title="signup.jinja" %}
```jinja
<!doctype html>
<html>
<head>{{ csrf_metatag }}</head>
<body>
<form method="post" action="/signup">
  {{ csrf_field() }}
  <input name="email" type="email">
  <button>Sign up</button>
</form>
</body>
</html>
```
{% endcode %}

In a form with file inputs, keep `csrf_field()` above them: `CSRF` looks for `_csrf` in the first 64 KB of a multipart
body and stops at the first file part (see [CSRF](../../reference/handlers/built-in.md#handlercsrf)). An AJAX upload can send the
token in the `X-CSRF-TOKEN` header instead.

<!-- prelude -->
```crystal
struct SignupPage
  include Azu::Response
  include Azu::Templates::Renderable

  def render
    view "signup.jinja"
  end
end

struct SignupPageEndpoint
  include Azu::Endpoint(Azu::Request, SignupPage)

  get "/signup"

  def call : SignupPage
    content_type "text/html"
    SignupPage.new
  end
end

struct SignupRequest
  include Azu::Request

  getter email : String

  def initialize(@email = "")
  end

  validate email, presence: true, match: /@/
end

struct SignupEndpoint
  include Azu::Endpoint(SignupRequest, Azu::Response::Empty)

  post "/signup"

  def call : Azu::Response::Empty
    redirect to: "/welcome", status: 303
  end
end
```

`view` gives the template the request's token, so the response needs no code for it. `GET /signup` sets the cookie
and writes the same token into the field:

```text
Set-Cookie: csrf_token=dpp9Rh…:1793026783:PzZZ0J…; path=/; max-age=86400; HttpOnly; SameSite=Strict

<input type="hidden" name="_csrf" value="dpp9Rh…:1793026783:PzZZ0J…" />
```

The browser sends both back with the form, and the `POST` reaches `SignupEndpoint`. A `POST` without the field, or
from a page of another site, is answered `403` with the detail `CSRF token validation failed`, and the endpoint does
not run.

{% hint style="info" %}
Templates take the token from `Azu::Handler::CSRF.default`. The handler you put in the chain accepts it because both
sign with `CSRF_SECRET`; keep the cookie and field names at their defaults so they also agree.
{% endhint %}

## Send the token from JavaScript

`{{ csrf_metatag }}`, in the `<head>` of the template above, prints the token for scripts:

```html
<meta name="_csrf" content="dpp9Rh…:1793026783:PzZZ0J…" />
```

Send it in the `X-CSRF-TOKEN` header. The cookie is `HttpOnly`, so a script cannot read it and takes the token from
the page; a same-origin `fetch` sends the cookie by itself:

```javascript
const token = document.querySelector('meta[name="_csrf"]').content;

await fetch("/signup", {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": token },
  body: JSON.stringify({ email: "ada@example.com" }),
});
```

## Exempt a webhook

A payment provider or a CI server posts without a token. Leave its paths out of the check:

```crystal
Azu::Handler::CSRF.new(skip_routes: ["/webhooks/"])
```

`skip_routes` entries are path prefixes: end one with `/`, since `"/webhooks"` would also exempt `/webhooks-admin`.
To exempt one exact path for every CSRF handler, call `Azu::Handler::CSRF.exempt("/stripe/events")` at boot.

{% hint style="danger" %}
An exempt path has no CSRF protection at all. Authenticate every webhook another way, usually by checking the
signature the sender puts in a header.
{% endhint %}

## Open a JSON API to another origin

A page served from another origin, `https://app.example.com`, calls your API with `fetch`. Allow that origin:

```crystal
Azu::Handler::CORS.new(
  origins: ["https://app.example.com"] of (String | Regex),
  methods: %w(GET POST DELETE),
  headers: %w(Content-Type Authorization),
  max_age: 600,
)
```

Before a JSON `POST`, the browser sends a preflight:

```text
OPTIONS /api/notes
Origin: https://app.example.com
Access-Control-Request-Method: POST
Access-Control-Request-Headers: content-type, authorization
```

The handler answers it itself, `200` with an empty body and these headers, and the endpoint does not run:

```text
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: POST
Access-Control-Allow-Headers: content-type, authorization
Access-Control-Max-Age: 600
Vary: Origin
```

The `POST` that follows reaches the endpoint, and its response carries `Access-Control-Allow-Origin:
https://app.example.com` and `Vary: Origin`. A request from any other origin is answered `403`. A request without
an `Origin` header, from a server or `curl`, passes untouched.

{% hint style="warning" %}
A preflight that names no request header is refused with `403`: a cross-origin `fetch` that sends a `DELETE` with no
header of its own fails. An API client that sends `Authorization` with every call is not affected.
{% endhint %}

An API that authenticates with a token in `Authorization` needs no CSRF check: a browser never adds that header by
itself, so another site cannot forge the request. Leave the API out of the check with
`skip_routes: ["/webhooks/", "/api/"]`. An API that relies on the session cookie instead (`credentials: true`) keeps
the check: send the token as in the previous section (`X-CSRF-TOKEN` is in the default `headers`). `CSRF` also
refuses a request from an origin other than the app's own, unless a `CORS` earlier in the chain allowed that origin,
so put `CORS` before `CSRF`.

## Rate-limit the login

`Azu::Handler::Throttle` counts every request of a client address, whatever its path. To limit the login alone, put
it behind a handler that sends it only those paths:

<!-- prelude -->
```crystal
class ThrottlePaths
  include HTTP::Handler

  def initialize(@paths : Array(String), @throttle : Azu::Handler::Throttle)
    @throttle.next = ->(context : HTTP::Server::Context) { call_next(context) }
  end

  def call(context : HTTP::Server::Context)
    if @paths.includes?(context.request.path)
      @throttle.call(context)
    else
      call_next(context)
    end
  end
end

struct LoginRequest
  include Azu::Request

  getter email : String
  getter password : String

  def initialize(@email = "", @password = "")
  end
end

struct LoginEndpoint
  include Azu::Endpoint(LoginRequest, Azu::Response::Empty)

  post "/login"

  def call : Azu::Response::Empty
    # check login_request.email and login_request.password, then start the session
    redirect to: "/account", status: 303
  end
end
```

```crystal
ThrottlePaths.new(["/login"], Azu::Handler::Throttle.new(
  interval: 60, duration: 900, threshold: 5, blacklist: [] of String, whitelist: [] of String,
))
```

Five attempts a minute pass. The sixth is answered `429` with `Retry-After: 900` and the error body your client
asks for (`Rate limit exceeded. Retry after 900 seconds.`), and the address stays blocked for 15 minutes, on
`/login` only: the rest of the app keeps answering it. Ten minutes later `Retry-After` says `300`.

Place it before `CSRF`, so an attempt refused for its token counts too.

## Run behind a proxy

When a proxy or load balancer terminates TLS and forwards to the app:

- `Throttle` identifies clients by the address of the connection and reads no header unless you list the proxies in
  `trusted_proxies:`; without it every visitor shares the proxy's address and five attempts lock everybody out. With
  it, the client is the right-most `X-Forwarded-For` address that is not a trusted proxy
  ([Behind a reverse proxy](../../reference/handlers/built-in.md#behind-a-reverse-proxy)).
- The `csrf_token` cookie gets `Secure` when the request has `X-Forwarded-Proto: https` (or when Azu terminates TLS
  itself). Make the proxy set that header, and `X-Forwarded-Host` if it rewrites `Host`, and replace the ones a client
  sends: `CSRF` compares the request's `Origin` with them.
- `Azu::Handler::SecurityHeaders` sends `Strict-Transport-Security` with `hsts: true`, or with the default stack's
  `hsts: :auto` to the requests the proxy marks with `X-Forwarded-Proto: https`. A proxy that does not forward the
  header needs `hsts: true` in your own handler, with a `content_security_policy:` if you have one.
- `Azu::Handler::IpSpoofing` answers `403` to a request whose `X-Real-IP` or `X-Client-IP` is not one of the
  addresses of its `X-Forwarded-For`, a sign that a client wrote the headers itself.
- The [template variables](../../reference/templates/helpers.md#request-variables) `secure` and `client_ip` are read
  from the `X-Forwarded-*` headers as they arrive: rely on them only when the proxy overwrites what the client sent.

## Put the chain together

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::SecurityHeaders.new(hsts: true),
  Azu::Handler::CORS.new(
    origins: ["https://app.example.com"] of (String | Regex),
    methods: %w(GET POST DELETE),
    headers: %w(Content-Type Authorization),
    max_age: 600,
  ),
  ThrottlePaths.new(["/login"], Azu::Handler::Throttle.new(
    interval: 60, duration: 900, threshold: 5, blacklist: [] of String, whitelist: [] of String,
  )),
  Azu::Handler::CSRF.new(skip_routes: ["/webhooks/", "/api/"]),
] of HTTP::Handler
```

`CORS` comes before the handlers that refuse requests, so their refusals still carry the CORS headers the browser
needs to show them to the calling page. `Static`, which the default stack ends with, is left out: add
`Azu::Handler::Static.new` last if the app serves files from `public/`.

## Test it

`Azu::Testing::Client#with_csrf` fetches a token from the CSRF handler of the chain and sends it with every write,
and a fake clock moves the throttle window without waiting:

```crystal
require "spec"
require "azu"
require "azu/testing"

def protected_handlers : Array(HTTP::Handler)
  [
    Azu::Handler::RequestId.new,
    Azu::Handler::Rescuer.new,
    ThrottlePaths.new(["/login"], Azu::Handler::Throttle.new(
      interval: 60, duration: 900, threshold: 5, blacklist: [] of String, whitelist: [] of String,
    )),
    Azu::Handler::CSRF.new(skip_routes: ["/webhooks/", "/api/"]),
  ] of HTTP::Handler
end

describe "protection" do
  it "refuses a form posted without its token" do
    client = Azu::Testing::Client.new(Azu::App.default, protected_handlers)

    client.post("/signup", form: {"email" => "ada@example.com"}).status_code.should eq 403
    client.with_csrf.post("/signup", form: {"email" => "ada@example.com"}).status_code.should eq 303
  end

  it "locks the login for 15 minutes after five attempts" do
    client = Azu::Testing::Client.new(Azu::App.default, protected_handlers, clock: Azu::Clock::Fake.new).with_csrf
    attempt = {"email" => "ada@example.com", "password" => "wrong"}

    5.times { client.post("/login", form: attempt).status_code.should eq 303 }
    refused = client.post("/login", form: attempt)
    refused.status_code.should eq 429
    refused.header("Retry-After").should eq "900"

    client.advance(16.minutes)
    client.post("/login", form: attempt).status_code.should eq 303
  end
end
```

## See also

- [Built-in handlers](../../reference/handlers/built-in.md)
- [Testing: sessions and CSRF](../../reference/api/testing.md#sessions-and-csrf)
- [Use sessions](use-sessions.md)
- [Middleware](../../explanation/concepts/middleware.md)
