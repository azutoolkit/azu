<div align="center"><img src="https://raw.githubusercontent.com/azutoolkit/azu/master/azu.png" alt="Azu" /></div>

# Azu

[![Crystal CI](https://github.com/azutoolkit/azu/actions/workflows/crystal.yml/badge.svg)](https://github.com/azutoolkit/azu/actions/workflows/crystal.yml) [![CodeQL](https://github.com/azutoolkit/azu/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/azutoolkit/azu/actions/workflows/github-code-scanning/codeql) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Azu is a web framework for Crystal built on typed contracts and real-time.** Every endpoint declares the request it accepts and the response it returns, Azu validates the request before your code runs, and the same contracts give you links, an OpenAPI document and tests. Live components, WebSockets, pub/sub and presence are in the box.

## Hello, contract

```crystal
require "azu"

module Hello
  include Azu
end

struct GreetRequest
  include Azu::Request

  getter name : String

  validate name, size: 2..30, message: "must be 2 to 30 characters"

  def initialize(@name = "")
  end
end

struct GreetResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {message: "Hello, #{@name}!"}.to_json
  end
end

struct GreetEndpoint
  include Azu::Endpoint(GreetRequest, GreetResponse)

  get "/hello"

  def call : GreetResponse
    content_type "application/json"
    GreetResponse.new greet_request.name
  end
end

Hello.start
```

```bash
crystal run hello.cr
curl "http://127.0.0.1:4000/hello?name=Ada"
# {"message":"Hello, Ada!"}

curl -H "Accept: application/problem+json" "http://127.0.0.1:4000/hello?name=A"
# {"type":"about:blank","title":"Validation Error","status":422,"detail":"The request could not be processed due to validation errors.","errors":{"name":["must be 2 to 30 characters"]},"instance":"/hello"}
```

`call` never ran for the second request: the contract failed first. Add `azu` to your `shard.yml` (`github: azutoolkit/azu`, `version: ~> 0.5.119`) and run `shards install`. The [getting started tutorial](docs/tutorials/getting-started.md) builds this out step by step.

## Get started in 5 minutes

The [Azu CLI](https://github.com/azutoolkit/azu_cli) generates a working app. You need Crystal 1.19.1 or newer.

```bash
git clone https://github.com/azutoolkit/azu_cli && cd azu_cli
shards install && sudo make install      # installs `azu` to /usr/local/bin

azu new blog --db sqlite --no-joobq      # a project, with its shards installed
cd blog
azu generate scaffold Post title:string body:text
azu db:setup                             # creates the SQLite database and runs the migration
azu dev                                  # builds, serves, and rebuilds when you change code
```

Open <http://localhost:4000/posts>. The scaffold gave you a model, a migration, request contracts, endpoints, pages, templates and CSRF-protected forms, named `Blog::Posts::CreateEndpoint`, `Blog::Posts::CreateRequest` and so on. `azu routes` lists them with their contract types.

```text
blog/
├── src/
│   ├── blog.cr          # the app: handlers, CSRF, configuration
│   ├── server.cr        # Blog.start
│   ├── endpoints/       # Endpoint(Request, Response)
│   ├── requests/        # contracts and validation
│   ├── pages/           # responses that render templates
│   ├── models/          # CQL models
│   ├── db/              # schema.cr and migrations/
│   └── channels/ components/ services/ middleware/
├── public/              # static files and Jinja templates
├── spec/
└── .env                 # PORT, CSRF_SECRET (git-ignored)
```

`azu new` defaults to PostgreSQL; pass `--db sqlite` to try things without a database server. All commands are in the [CLI reference](https://github.com/azutoolkit/azu_cli/blob/master/CLI_REFERENCE.md).

## A tour

**Contracts are checked before your code.** A request that fails validation gets a `422` with the failing fields, as an [RFC 7807](https://www.rfc-editor.org/rfc/rfc7807) problem document (`application/problem+json` when the client asks for it). A request that cannot be built at all gets a `400`. See the example above and [Handle validation errors](docs/how-to/validation/handle-validation-errors.md).

**Links and forms follow your routes.** Each endpoint generates template helpers from its verb and type, so renaming a route updates every link:

```jinja
{{ link_to_get_posts_show("Read it", id=post.id) }}
{{ form_for_patch_posts_update(id=post.id) }}
  {{ csrf_field() }}
  ...
{{ end_form() }}
```

**Live components keep state on the server.** The browser sends events over a WebSocket and gets back only the HTML that changed:

```crystal
class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def render
    div class: "counter" do
      h2 "#{label}: #{count}"
      button "+1", **spark_click(:increment)
      button "+10", **spark_click(:increment, by: 10)
    end
  end
end
```

**Channels, pub/sub and presence.** Topics work in one process or across many through Redis:

```crystal
class RoomChannel < Azu::Channel
  include Azu::Presence::Tracked

  ws "/rooms/:room"

  def on_connect
    subscribe room
    presence_updates room # joins and leaves reach this socket
    track_presence room, params["user"]
  end

  def on_message(message : String)
    broadcast room, message
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  private def room : String
    "room:#{context.request.path_params["room"]}"
  end
end
```

**A test client that goes through the real router.** No socket, the whole handler chain:

```crystal
require "azu/testing"

client = Azu::Testing::Client.new
response = client.get "/hello", params: {name: "Ada"}
response.status_code        # => 200
response.json["message"]    # => "Hello, Ada!"
```

**OpenAPI from the contracts.** The document is built from your `Endpoint(Request, Response)` types, so it cannot drift:

```crystal
info = Azu::OpenAPI::Info.new("Hello API", "1.0.0")
puts Azu::OpenAPI.document(Azu::App.default, info).to_json(pretty: true)
```

**A dashboard while you develop.** `require "azu/dev"` adds routes, configuration, logs and timings at `/dev-dashboard`, and with CQL every query tied to its request, with N+1 detection. See the [tutorial](docs/tutorials/getting-started.md#5-the-development-dashboard).

## Everything in the box

Features marked *opt-in* need their own `require`. The [full list](docs/explanation/features.md) has a sentence and a link for each.

| | |
|---|---|
| **Routing** | Typed endpoints, radix router, `scope`, `mount`, apps as values (`Azu::App`) · [Router](docs/reference/api/router.md), [App](docs/reference/api/app.md) |
| **Contracts** | `Azu::Request` with validation rules, typed params, uploads, `422` problem documents · [Request](docs/reference/api/request.md) |
| **Responses** | Content negotiation, streaming and server-sent events, error classes and pages · [Response](docs/reference/api/response.md), [Streaming](docs/reference/api/streaming.md) |
| **Real-time** | Channels, `PubSub` (memory or Redis), presence, Spark live views · [Channel](docs/reference/api/channel.md), [Presence](docs/reference/api/presence.md), [Spark](docs/explanation/spark-live-views.md) |
| **Templates** | Jinja (Crinja), compiled at boot outside development, form/link/asset/date/number/HTML/i18n helpers · [Helpers](docs/reference/templates/helpers.md) |
| **Security** | CSRF, security headers, CORS, throttling, IP spoofing guard, session seam, secrets · [Handlers](docs/reference/handlers/built-in.md), [Env](docs/reference/configuration/env.md) |
| **Operations** | Memory and Redis cache, static files, compression, health check, request ids, graceful shutdown · [Cache](docs/reference/api/cache.md), [Shutdown](docs/how-to/deployment/graceful-shutdown.md) |
| **Tooling** | OpenAPI 3.1 · test client (*opt-in* `azu/testing`) · dev dashboard (*opt-in* `azu/dev`) · CQL bridge with SQL insight (*opt-in* `azu/cql`) · `.env` loading (`azu/env`) · [CLI](https://github.com/azutoolkit/azu_cli) · [Testing](docs/reference/api/testing.md), [OpenAPI](docs/reference/api/openapi.md), [CQL bridge](docs/reference/api/cql-bridge.md) |

## Performance

Azu is not the fastest thing you can write in Crystal, and it does not claim to be. The repository has a [reproducible benchmark suite](benchmark/README.md) that compares it with a hand-written `HTTP::Server` and with Kemal, Lucky and Athena, same machine, same responses, same load. The numbers below are one snapshot, not a promise.

Measured on 2026-10-25: Azu 0.5.119 (commit 36869c8), Crystal 1.19.1 (`--release`), a 4 vCPU shared virtual machine, wrk with 64 connections, median of 5 runs of 10 seconds, servers and load generator on separate CPUs. Each cell is requests per second as a percentage of the hand-written `HTTP::Server` baseline (97,825 req/s on plaintext).

| Scenario | Azu (minimal stack) | Kemal | Lucky | Athena |
|---|---:|---:|---:|---:|
| plaintext | 90 | 76* | 82 | 57 |
| JSON | 89 | 80 | 82 | 55* |
| 100 parameterized routes | 86 | 54 | 83 | 57 |
| template | **23** | 63* | 50 | 69 |
| one SQLite row | 81 | 66* | 81 | 59 |
| 20 SQLite rows | **75** | 77* | 89 | 78 |

\* the repetitions disagreed by more than 5 %, so treat the row as indicative.

What the table does not say:

- "Minimal stack" is the router, the endpoint and `Rescuer` only. Azu's default stack also runs request ids, security headers and static file lookup on every request, which the other frameworks' defaults do not do. An earlier run of the default stack (before a hot-path cleanup that has since landed) measured 62 to 73 % of the baseline on plaintext, JSON and routing; it has not been re-run, so do not quote it either.
- **Templates are Azu's weak spot.** Jinja (Crinja) is parsed and rendered per request; the others run ECR the compiler turned into plain code. This compares template systems, not routers.
- **The ORM costs something.** Azu was the only app going through an ORM (CQL). With raw SQLite in the same app, the 20 row scenario measured 92 % instead of 75 %. Lucky used raw SQL too.
- WebSocket fan-out was limited by the load generator for every framework, so it says nothing about who is faster.
- One shared VM is noisy. Compare these numbers with each other, never with numbers from another machine. Method, fairness rules and known confounds: [benchmark/README.md](benchmark/README.md).

## Documentation

- **New here?** [Getting started](docs/tutorials/getting-started.md), then [Building a user API](docs/tutorials/building-a-user-api.md).
- **Doing a task?** [How-to guides](docs/README.md#how-to-guides).
- **Looking something up?** [Reference](docs/README.md#reference).
- **Want the why?** [Explanation](docs/README.md#explanation), starting with [Everything in the box](docs/explanation/features.md).
- **Upgrading?** [Migrate to 0.6](docs/how-to/migrate-to-0.6.md) and [breaking changes](docs/reference/breaking-changes.md).

## Status and compatibility

- Azu is 0.x: the API can still change between minor versions, and every break is written down in [breaking changes](docs/reference/breaking-changes.md).
- Crystal 1.19.1 or newer. CI runs the oldest supported version and the latest release.
- Redis is optional: it backs the cache, pub/sub and presence when you want them shared between processes.
- Databases go through [CQL](https://github.com/azutoolkit/cql) (`azu/cql` needs cql 0.0.609 or newer). The end-to-end checks of generated apps run on SQLite; PostgreSQL apps are only booted in CI.
- Every Crystal example in this README and in the checked docs pages is compiled in CI against the code in this repository.

## Contributing

Bug reports and pull requests are welcome. [Contributing setup](docs/contributing/setup.md) covers building and testing; [standards](docs/contributing/standards.md) covers style. Run `crystal spec` and `crystal tool format --check src spec` before you push.

## License

MIT, see [LICENSE](LICENSE). Created by [Elias J. Perez](https://github.com/eliasjpr) and the [contributors](https://github.com/azutoolkit/azu/graphs/contributors).
