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
Fields named by the path (`/users/:id`) fill the path.

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

`Client.new(app, clock: Azu::Clock::Fake.new)` runs every request on that clock. `client.advance(10.minutes)`
moves it, which ages cookies, cache entries, throttle windows and tokens without sleeping.

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

`receive(timeout = 2.seconds)` raises `WebSocket::Timeout`; `receive?` answers nil instead. `close` sends a
close frame and waits for the channel's `on_close`.

## Live components

`Azu::Testing.mount(Type, **props) { |view| ... }` is `Azu::Spark::Testing.mount`; see the Spark
documentation for `view.trigger`, `view.html` and `view.assigns`.
