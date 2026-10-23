# Testing Reference

`Azu::Testing` drives an `Azu::App` in process: no socket is opened, yet a request goes through the
app's real scope, handler chain and router, and a WebSocket through the real upgrade handshake. It is
opt-in; `require "azu"` does not load it.

```crystal
require "azu"
require "azu/testing"
```

In a spec, require it next to your app (`require "azu/testing"` after `require "spec"`).

## A first test

```crystal
require "azu"
require "azu/testing"

struct PingEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "pong"
  end
end

app = Azu::App.new
app.routes { get "/ping", PingEndpoint }

client = Azu::Testing::Client.new(app)
response = client.get "/ping"
response.status_code # => 200
response.body        # => "pong"
```

## Client

`Azu::Testing::Client.new(app = Azu::App.default, handlers, clock: nil, follow_redirects: false)`

* `handlers` is the chain after the app's scope. The default is `RequestId` and `Rescuer`; pass your own
  list (`app.default_handlers` gives the ones `Azu.start` uses). A handler instance can be in one chain
  only, so build a fresh list per client.
* Requests run inside the app's scope, so `Azu.current_config` is the app's configuration. An exception
  that escapes the chain becomes a 500, as on a server, and is kept in `Response#error`.
* Each client has its own cookie jar and default headers. Nothing is shared between clients.

### Requests

`get`, `post`, `put`, `patch`, `delete`, `head` and `options` take the path and keyword arguments:

| Argument  | Meaning                                                              |
| --------- | -------------------------------------------------------------------- |
| `headers` | `Hash`, `NamedTuple` or `HTTP::Headers`, merged over the client's    |
| `body`    | A raw `String`                                                       |
| `json`    | Anything with `to_json`; sets `Content-Type: application/json`      |
| `form`    | A `Hash` or `NamedTuple`; sent as `application/x-www-form-urlencoded` |
| `params`  | Appended to the query string                                         |

`json: nil` and `json: false` are sent as the bodies `null` and `false`. In `form` and `params`, an array
repeats its key (`ids=1&ids=2`), `nil` leaves the field out and every other value is its `to_s`.

```crystal
require "azu"
require "azu/testing"

struct NameRequest
  include Azu::Request

  getter name : String = ""

  def initialize(@name = "")
  end
end

struct Greeting
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct GreetEndpoint
  include Azu::Endpoint(NameRequest, Greeting)

  def call : Greeting
    Greeting.new "hello #{name_request.name}"
  end
end

app = Azu::App.new
app.routes { post "/greet", GreetEndpoint }

client = Azu::Testing::Client.new(app)
client.post("/greet", json: {name: "Ada"}).body                 # => "hello Ada"
client.post("/greet", form: {"name" => "Grace"}).body           # => "hello Grace"
client.request("POST", "/greet", body: %({"name":"Lin"}), headers: {"Content-Type" => "application/json"}).body
```

`client.accept(:json)` (also `:html`, `:text`, `:xml`) and `client.request_id = "abc"` set default headers;
`client.headers` is the default header set itself.

### Response

`Response` is a value: `status`, `status_code`, `headers`, `body`, `header(name)`, `content_type`,
`success?`, `redirect?`, `location`, `cookies`, `problem?` (an `application/problem+json` body), `error`,
`json` (a `JSON::Any`) and `json(Type)` (any `JSON::Serializable`).

```crystal
require "azu"
require "azu/testing"

struct Point
  include JSON::Serializable

  getter x : Int32
  getter y : Int32
end

struct PointEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "application/json"
    context.response << %({"x":1,"y":2})
  end
end

app = Azu::App.new
app.routes { get "/point", PointEndpoint }

response = Azu::Testing::Client.new(app).get "/point"
response.json["x"].as_i    # => 1
response.json(Point).y     # => 2
```

### Typed calls

`client.post(EndpointType, request)` takes the path from the route the endpoint is registered at on that
app (mount prefixes included) and serializes the request struct. Passing a request of another type than the
endpoint's contract is a compile error. The encoding follows the OpenAPI document: GET, DELETE, HEAD and
OPTIONS send the fields as query parameters, the other verbs a JSON body (`form: true` sends a form).
Fields named by the path (`/users/:id`) fill the path; a wildcard (`/files/*path`) keeps its slashes and
encodes each segment. The route is looked up by verb: an endpoint that is not routed for the verb, or is routed
at several paths for it, raises `ArgumentError` naming what is routed (use the path form then). In the named
form (`client.get(Endpoint, id: 8)`) the field names `headers` and `form` are the call's own arguments; send such a field
with a request struct.

```crystal
require "azu"
require "azu/testing"

struct ShowRequest
  include Azu::Request

  getter id : Int64 = 0_i64
  getter verbose : Bool = false

  def initialize(@id = 0_i64, @verbose = false)
  end
end

struct ShowResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct ShowEndpoint
  include Azu::Endpoint(ShowRequest, ShowResponse)

  def call : ShowResponse
    ShowResponse.new "#{show_request.id} #{show_request.verbose}"
  end
end

app = Azu::App.new
app.routes { get "/items/:id", ShowEndpoint }

client = Azu::Testing::Client.new(app)
client.get(ShowEndpoint, ShowRequest.new(7_i64, true)).body # => "7 true"
client.get(ShowEndpoint, id: 8).body                         # => "8 false"
```

### Cookies and redirects

Cookies set by a response are sent back with the next request (`client.cookies`), until they expire or the
server deletes them. `Secure` and domains are not modelled. `client.follow_redirects = true` follows up to
ten redirects (301 and 302 turn a write into a GET, 303 always does, 307 and 308 keep the method) and raises
`Azu::Testing::TooManyRedirects` beyond that.

### Sessions and CSRF

`client.login_with { |session| session["user_id"] = "7" }` starts a session in an in-memory
`Azu::SessionAdapter` installed on the app (`Azu::Testing::Sessions`). It refuses an app that has an adapter
of its own: log in through its endpoints there.

`client.with_csrf` asks the `Azu::Handler::CSRF` in the client's handlers for a token and sends it, and
the cookie that goes with it, on every POST, PUT, PATCH and DELETE.

```crystal
require "azu"
require "azu/testing"

struct SaveEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    user = Azu.session_adapter.try(&.session(context)).try(&.["user_id"]?)
    context.response << "saved by #{user}"
  end
end

app = Azu::App.new
app.routes { post "/save", SaveEndpoint }

csrf = Azu::Handler::CSRF.new(secure_cookies: false)
client = Azu::Testing::Client.new(app, [csrf] of HTTP::Handler)
client.login_with { |session| session["user_id"] = "7" }.with_csrf
client.post("/save").body # => "saved by 7"
```

### Time

`Client.new(app, clock: Azu::Clock::Fake.new)` gives the client a clock, and `client.advance(10.minutes)`
moves it. It affects exactly two things: code that runs during a request of this client and reads
`Azu::Clock` (cache TTLs, throttle windows, token lifetimes and the like), and the client's own cookie jar
(`client.cookies`), which ages with the clock inside and outside requests. It does not affect your spec
reading `Azu::Clock.now`, code that calls `Time.utc` directly, or fibers that outlive a request (a WebSocket
channel runs on whatever clock is installed when it acts).

`Azu::Clock` is process wide, so the client installs its clock around each request and restores the previous
one afterwards; requests of clients that have a clock run one at a time to keep that safe.

### Cleaning up

`login_with` and `with_csrf` install the in-memory session adapter on the app's configuration. `client.close`
removes it (the last open client of the app does), and `Azu::Testing::Client.open(app) { |client| ... }`
closes for you. Close clients in an `after_each` when you share `Azu::App.default` between examples.

### Known limits

* Redirects to another host are returned, not followed.
* Cookies ignore `Secure`, `SameSite` and domains; paths are honoured (`/admin` does not match `/administrator`).
* There is no socket: request-target parsing, keep-alive and connection handling belong to `HTTP::Server`
  and are not exercised. Keep a few specs against a real server (`app.server` and `bind_unused_port`).
* The WebSocket client reads text frames only.
* An exception that escapes the chain is a 500 with the exception in `Response#error`, as on a server.

## WebSocket

`client.connect("/path")` performs the handshake through the app (with the client's cookies) and returns
an `Azu::Testing::WebSocket`. The frames travel over a pair of in-process pipes, not a port, so there is
nothing to bind and nothing to clean up but the socket itself. A refused handshake raises
`WebSocket::Rejected`, which carries the `Response`.

```crystal
require "azu"
require "azu/testing"

class EchoChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
    send "echo:#{message}"
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

app = Azu::App.new
app.routes { ws "/echo", EchoChannel }

socket = Azu::Testing::Client.new(app).connect "/echo"
socket.send "hi"
socket.receive           # => "echo:hi"
socket.receive?(10.milliseconds) # => nil
socket.close
```

`receive(timeout = 2.seconds)` raises `WebSocket::Timeout`, or `WebSocket::Closed` once the socket is closed; `receive?` answers nil instead. `close` sends a
close frame and waits for the channel's `on_close`.

## Live components

`Azu::Testing.mount(Type, **props) { |view| ... }` is `Azu::Spark::Testing.mount`; see the Spark
documentation for `view.trigger`, `view.html` and `view.assigns`.
