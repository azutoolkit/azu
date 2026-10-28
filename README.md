<div align="center"><img width="2560" height="1040" alt="azu-readme-cover" src="https://github.com/user-attachments/assets/68494bb9-c90f-4afb-83bd-6f3a3c872e5c" /></div>

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

Put this in `hello.cr`, with a `shard.yml` next to it, and install:

```yaml
name: hello
version: 0.1.0
crystal: ">= 1.22.1"
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.119
```

```bash
shards install
crystal run hello.cr
curl "http://127.0.0.1:4000/hello?name=Ada"
# {"message":"Hello, Ada!"}

curl -H "Accept: application/problem+json" "http://127.0.0.1:4000/hello?name=A"
# {"type":"about:blank","title":"Validation Error","status":422,"detail":"The request could not be processed due to validation errors.","errors":{"name":["must be 2 to 30 characters"]},"instance":"/hello"}
```

`call` never ran for the second request: the contract failed first. The [getting started tutorial](docs/tutorials/getting-started.md) builds this out step by step.

## Get started in 5 minutes

The [Azu CLI](https://github.com/azutoolkit/azu_cli) generates a working app. You need Crystal 1.22.1 or newer with `shards`, a C toolchain, and the development libraries Crystal and the CLI link against (on Debian or Ubuntu: `build-essential libreadline-dev libevent-dev libssl-dev libxml2-dev libyaml-dev libgmp-dev libsqlite3-dev`).

```bash
git clone https://github.com/azutoolkit/azu_cli && cd azu_cli
shards install
make install PREFIX=$HOME/.local         # builds `azu` into ~/.local/bin (put it on your PATH)
cd ..

azu new blog --db sqlite --no-joobq --yes   # a project, with its shards installed
cd blog
azu generate scaffold Post title:string body:text
azu db:setup                             # creates the SQLite database and runs the migration
azu dev                                  # builds, serves, and rebuilds when you change code
```

The first `azu dev` build takes a minute or so. Installing with a `PREFIX` you own keeps `bin/` and `lib/` of the clone from becoming root-owned, which a plain `sudo make install` (it rebuilds, as root) would do.

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

**Contracts are checked before your code.** A request that fails validation never reaches `call`: bad values get a `422` problem document, a request that cannot be built at all gets a `400`. See [Handle validation errors](docs/how-to/validation/handle-validation-errors.md).

**Links and forms follow your routes.** Each endpoint generates template helpers from its verb and type, so renaming a route updates every link:

```jinja
{{ link_to_get_posts_show("Read it", id=post.id) }}
{{ form_for_patch_posts_update(id=post.id) }}
  {{ csrf_field() }}
  ...
{{ end_form() }}
```

**Spark components keep state on the server.** The browser sends events over a WebSocket and gets back only the HTML that changed:

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

**OpenAPI from the contracts.** The document is built from your `Endpoint(Request, Response)` types, so it is generated from your types and cannot go stale:

```crystal
info = Azu::OpenAPI::Info.new("Hello API", "1.0.0")
puts Azu::OpenAPI.document(Azu::App.default, info).to_json(pretty: true)
```

**A dashboard while you develop.** `require "azu/dev"` adds routes, configuration, logs and timings at `/dev-dashboard`, and with CQL every query tied to its request, with N+1 detection. See the [tutorial](docs/tutorials/getting-started.md#5-the-development-dashboard).

## Everything in the box

Features marked *opt-in* need their own `require`. The [full list](docs/explanation/features.md) has a sentence and a link for each.

| Area | What you get | Learn more |
|---|---|---|
| Routing | Typed endpoints, segment-tree router, `scope`, `mount`, apps as values (`Azu::App`) | [Router](docs/reference/api/router.md), [App](docs/reference/api/app.md) |
| Contracts | `Azu::Request` with validation rules, typed params, uploads, `422` problem documents | [Request](docs/reference/api/request.md) |
| Responses | Content negotiation, streaming and server-sent events, error classes and pages | [Response](docs/reference/api/response.md), [Streaming](docs/reference/api/streaming.md) |
| Real-time | Channels, `PubSub` (memory or Redis), presence, Spark live views | [Channel](docs/reference/api/channel.md), [Presence](docs/reference/api/presence.md), [Spark](docs/explanation/spark-live-views.md) |
| Templates | Jinja (Crinja), preloaded at boot outside development, form, link, asset, date, number, HTML and i18n helpers | [Helpers](docs/reference/templates/helpers.md) |
| Security | CSRF, security headers, CORS, throttling, IP spoofing guard, session seam, secrets | [Handlers](docs/reference/handlers/built-in.md), [Env](docs/reference/configuration/env.md) |
| Operations | Memory and Redis cache, static files, compression, health check, request ids, graceful shutdown | [Cache](docs/reference/api/cache.md), [Shutdown](docs/how-to/deployment/graceful-shutdown.md) |
| Testing and docs | Test client (*opt-in* `azu/testing`), OpenAPI 3.1 from your contracts | [Testing](docs/reference/api/testing.md), [OpenAPI](docs/reference/api/openapi.md) |
| Development | Dashboard (*opt-in* `azu/dev`), SQL and N+1 insight (*opt-in* `azu/cql`), `.env` loading (`Azu::Env.load_all`, which generated apps call before `require "azu"`), the [CLI](https://github.com/azutoolkit/azu_cli) | [CQL bridge](docs/reference/api/cql-bridge.md), [Azu::Env](docs/reference/configuration/env.md) |

## Performance

Azu is not the fastest thing you can write in Crystal, and it does not claim to be. The repository has a [reproducible benchmark suite](benchmark/README.md) that compares it with a hand-written `HTTP::Server`, Kemal and Lucky: same machine, same responses, same load. The numbers below are one snapshot, not a promise.

Measured on 2026-10-26 (UTC): Azu 0.5.123 at commit cc96c64 with CQL 0.0.808 (an uncommitted bump in the benchmark app on a dirty working tree; `scripts/bench.sh` as committed builds the app with CQL 0.0.541), Crystal 1.22.1 (`--release`), a 4 vCPU shared virtual machine, wrk with 64 connections, median of 5 runs of 10 seconds, servers and load generator on separate CPUs. That is older than the current release (0.9.x). It predates the near-zero default middleware (#229), the segment-tree router (#234) and the server limits (#256, #258), so the default-stack column and the middleware gap may not describe the current release; a re-run on 0.9.x is pending. Each cell is requests per second as a percentage of the baseline in the same scenario (82,261 req/s on plaintext), a hand-written `HTTP::Server`.

| Scenario | Azu (default stack) | Azu (minimal stack) | Kemal | Lucky |
|---|---:|---:|---:|---:|
| plaintext | 80 | 90 | 73 | 82 |
| JSON | 80 | 84* | 73 | 80 |
| 100 parameterized routes | 77 | 81 | 73 | 83* |
| template† | **22** | **22** | 82 | 46 |
| one SQLite row | 72 | 77 | 77 | 78 |
| 20 SQLite rows | **73** | **75** | 90 | 91 |

\* the repetitions disagreed by more than 5 %, so treat the cell as indicative. † the baseline itself was noisy in this scenario (5.5 %), so the percentages in that row are soft; Azu's own numbers were steady. The WebSocket scenario is left out: Lucky has no WebSocket support, and for the others the load generator was the limit (about 190,000 deliveries per second each), so it says nothing about who is faster. Athena, which earlier snapshots included, was not part of this run.

Good to know when you read it:

- **Two Azu columns.** The default stack runs `RequestId`, `SecurityHeaders` and `Static` on every request and sends more headers. The minimal stack is the router, the endpoint, `Rescuer` and the small `App::Scope` wrapper every `Azu::App` puts in front of the chain, so the gap between the columns is what that default middleware costs: about 10 points on plaintext, 4 to 5 on JSON, routing and one SQLite row, about 2 on 20 rows, and not measurable on templates.
- **Templates are Azu's weak spot.** Jinja (Crinja) templates are parsed once at boot but interpreted on every render; the others run ECR the compiler turned into plain code. This compares template systems, not routers.
- **The ORM costs something.** Azu is the only app going through an ORM (CQL 0.0.808); the others call SQLite directly. With raw SQLite in the same Azu app the 20 row scenario measured 92 to 93 % instead of 73 to 75 %, and the one row scenario 78 to 80 % instead of 72 to 77 %.
- **Do not compare with older snapshots.** The previous one (Azu 0.5.119, Crystal 1.19.1) showed higher absolute numbers, but the whole machine was about 15 to 25 % slower this time (the unchanged baseline app lost that much), and the compiler changed too. We cannot tell the compiler effect from the machine's mood, so the percentages are only good within this one run, and differences of a few points are inside its run-to-run spread. Read it as "Azu sits between 77 and 90 % of the hand-written server on plaintext, JSON and routing", not as a speed-up or a regression.
- One shared VM is noisy. Compare these numbers with each other, never with numbers from another machine.

The raw snapshot is committed: [report](benchmark/snapshots/2026-10-26-v0.5.123-cql0.0.808-cr1.22.1.md) and [JSON](benchmark/snapshots/2026-10-26-v0.5.123-cql0.0.808-cr1.22.1.json). To reproduce on your own machine, run `scripts/bench.sh`; method, fairness rules and known confounds are in [benchmark/README.md](benchmark/README.md).

## Documentation

- **New here?** [Getting started](docs/tutorials/getting-started.md), then [Building a user API](docs/tutorials/building-a-user-api.md).
- **Doing a task?** [How-to guides](docs/README.md#how-to-guides).
- **Looking something up?** [Reference](docs/README.md#reference).
- **Want the why?** [Concepts](docs/README.md#concepts), starting with [Everything in the box](docs/explanation/features.md).
- **Want running code?** [Examples](docs/examples.md): the apps in `playground/` and how to start them.
- **Upgrading?** [Migrate to 0.6](docs/how-to/migrate-to-0.6.md) and [breaking changes](docs/reference/breaking-changes.md).

## Status and compatibility

- Azu is 0.x: the API can still change between minor versions, and every break is written down in [breaking changes](docs/reference/breaking-changes.md).
- Crystal 1.22.1 or newer. CI runs 1.22.1 (the oldest supported version) and the latest release.
- Redis is optional for Azu: it backs the cache, pub/sub and presence when you want them shared between processes. The JoobQ job queue that `azu new` includes by default does need it (`--no-joobq` leaves it out).
- Databases go through [CQL](https://github.com/azutoolkit/cql) (`azu/cql` needs cql 0.0.609 or newer, see the [CQL bridge page](docs/reference/api/cql-bridge.md)). The end-to-end checks of generated apps run on SQLite; PostgreSQL apps are only booted in CI.
- Most Crystal examples in this README and in the docs are compiled in CI against the code in this repository; the ones that need another shard or another file are marked as fragments and are not.

## Contributing

Bug reports and pull requests are welcome. [Contributing setup](docs/contributing/setup.md) covers building and testing; [standards](docs/contributing/standards.md) covers style. Run `crystal spec` and `crystal tool format --check src spec` before you push.

## License

MIT, see [LICENSE](LICENSE). Created by [Elias J. Perez](https://github.com/eliasjpr) and the [contributors](https://github.com/azutoolkit/azu/graphs/contributors).
