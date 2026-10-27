---
description: "Build CQL models from request contracts, responses from models, and run each request in a CQL transaction."
---

# CQL bridge

`require "azu/cql"` (opt-in, see [Database dashboard](../database-dashboard.md)) also connects Azu's request and
response contracts to CQL models. It is plain compile-time code: no runtime reflection, no CQL patches beyond one
method on `CQL::ActiveRecord::Validations`. It needs the same CQL release as the dashboard (`azu/cql` needs 0.0.609 or newer, the version `shard.yml` requires; the code itself only checks for the telemetry hooks, which first shipped in 0.0.541, and says so at compile time on an older release). The dashboard keeps bound values and database error details out of what it shows unless `database.show_params` is on in development; hand-written SQL appears as written. See [what the tab shows of your data](../database-dashboard.md#what-the-tab-shows-of-your-data).

```crystal
require "sqlite3"
require "azu"
require "azu/cql"

AppDB = Azu::CQL.schema :app, "sqlite3://./bridge_example.db" do
  table :people do
    primary :id, Int64
    column :name, String
    column :email, String
    column :bio, String, null: true
    column :created_at, Time, null: true
  end
end

class Person
  include CQL::ActiveRecord::Model(Int64)
  include Azu::CQL::FromRequest # Person.from_request(request)
  db_context AppDB, :people

  property name : String
  property email : String
  property bio : String?
  property created_at : Time?

  validate name, presence: true, size: 2..20
  validate email, presence: true, match: /@/

  def initialize(@name : String, @email : String)
  end
end

struct SignUp
  include Azu::Request

  getter name : String
  getter email : String
  getter bio : String?
end

struct PersonResponse
  include Azu::Response
  include Azu::CQL::FromModel # PersonResponse.from(person)

  getter id : Int64?
  getter name : String
  getter created_at : String?

  def initialize(@id : Int64?, @name : String, @created_at : String?)
  end

  def render : String
    {id: id, name: name, created_at: created_at}.to_json
  end
end

struct CreatePerson
  include Azu::Endpoint(SignUp, PersonResponse)

  post "/people"

  def call : PersonResponse
    person = sign_up_contract.to_model(Person).valid_or_422!
    person.save!
    status 201
    PersonResponse.from(person)
  end
end

app = Azu::App.new
app.routes { endpoint CreatePerson }
handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::CQL::Middleware.new(AppDB, transaction: true),
] of HTTP::Handler
server = app.server(handlers)
```

## API

### Request to model

`request.to_model(Person)` and `Person.from_request(request)` build the model with the constructor it declares:

* every `initialize` argument is read from the request reader of the same name; the constructor that consumes the
  most arguments and needs nothing the request lacks is used;
* the remaining request fields are assigned through the model's setters (`property`); request fields the model has no
  setter for are ignored, and `id`, `created_at` and `updated_at` are never copied (as constructor arguments or
  setters) unless named in `only:`;
* a field named like a renamed attribute never overwrites the renamed value (`rename: {name: :full_name}` ignores a
  request field `name`);
* a required constructor argument the request cannot provide, a nilable field into a non-nilable one, and types that
  are not convertible are **compile errors** that name both sides, for example
  `cannot map SignUp#email (Int32) to Person#email (String)`.

Types convert when no information is lost: identical or narrower, `T` to `T?`, `Int32` to `Int64`, `Float32` to
`Float64`, and `Time` / `UUID` to `String` (RFC 3339 / canonical). A nilable source goes through `try`.

To customize, declare the mapping in the request: `map_to Person, only: [...], except: [...], rename: {name: :full_name}`
(`rename` maps a model attribute to the request field it reads). It defines `to_model(Person.class)` for that model
and takes precedence over the default.

### Mass assignment: list the fields with `only:`

{% hint style="danger" %}
Matching is by name, so **every request field that the model has a setter or constructor argument for is copied**,
including `role`, `admin`, `user_id` or `password_digest` if the request declares them.
{% endhint %}

The request struct is the allow-list, which is safe as long as it only declares what a client may set; when the request is shared with other
code, or the model has sensitive attributes, state the list explicitly. Declare it once next to the request:

<!-- skip -->
```crystal
struct UpdateProfile
  include Azu::Request

  getter name : String
  getter bio : String?
  getter role : String = "user" # declared for another use: must not reach the model

  map_to Person, only: [:name, :bio]
end
```

### Model to response

`include Azu::CQL::FromModel` gives `Response.from(model)`: the response's constructor arguments are read from the
model readers of the same name, with the conversions above (so `created_at : Time?` fills a `String?`). A response
whose only constructor takes the model itself (`initialize(record)`) has nothing to match and is a compile error:
declare `initialize(@id : Int64?, @name : String, ...)` or keep your own constructor. `map_from User, except:, rename:`
customizes it like `map_to`.

### `Azu::CQL::Middleware`

A plain `HTTP::Handler` for `App#server([...])` / `App#default_handlers`:

<!-- skip -->
```crystal
app = Azu::App.new
handlers = app.default_handlers + [Azu::CQL::Middleware.new(transaction: true) { AppDB }] of HTTP::Handler
server = app.server(handlers)
```

(The block form resolves the schema on first use, like `Azu::CQL.attach { }`.)

* It opens the request's `Azu::RequestContext` (reusing the one `RequestId` opened), so every statement and
  transaction CQL reports to `Azu::QueryStore` through `Azu::CQL::Instrumentor` carries the request id and shows up
  tagged in the dashboard. `Azu::Instrumentation` is not involved: its hooks cover the cache, components and app
  prepare/finalize, while SQL is observed through `CQL::Telemetry`.
* With `transaction: true` the rest of the chain runs in one CQL transaction on one connection (held for the whole
  request, even one that never queries). It commits when the response status is below `rollback_from` (400 by
  default) and rolls back on an exception or a status at or above it. Rolling back by status writes nothing to the log
  (CQL only warns for its own `DB::Rollback`), but it also drops writes the handler meant to keep on a 4xx, such as a
  failed-login counter: record those outside the request transaction, or set `rollback_from: 500`.
* Place it after `Rescuer` (the exception keeps propagating and is rendered there) and after `Static` and any health
  or metrics handler (they should not hold a connection). Do not use it for streaming or WebSocket routes: the
  transaction would stay open as long as the stream does.
* **Nesting.** `Schema#transaction` (so `Model.transaction` too) called inside a request the middleware already
  wrapped runs as a SAVEPOINT on the request's connection: rolling it back undoes only its block, and what it commits
  is kept only if the request transaction commits.
* Transactions are tied to the serving fiber, so concurrent requests never share one.
* Without `transaction`, CQL keeps checking out a pooled connection per statement; only the tagging applies.
* Escaping `CQL::RecordInvalid`, `CQL::ValidationError` and the model validation error become 422s.
* With `query_cache: true` it also counts the request's repeated queries: see
  [Repeated queries per request](#repeated-queries-per-request). Off by default.

{% hint style="warning" %}
If the commit itself fails, the middleware discards the body the handler buffered (while headers have not been sent)
before re-raising, so the `Rescuer`'s error page is not appended to a success body. A response already flushed, which
Crystal does once the body exceeds its output buffer (about 8 KB), cannot be taken back: for large bodies the client
may see the success status and a truncated reply.
{% endhint %}

### Repeated queries per request

Running the same `SELECT` (same SQL, same parameters) twice in one request is usually a missing variable or a missing
`preload`. `query_cache: true` makes the middleware open CQL's request query cache for each request, under the
request's own id (the `X-Request-ID` that `RequestId` accepted or generated), and `Azu::CQL.request_cache_stats` tells
you how it went so far:

```crystal
require "azu"
require "azu/cql"
require "sqlite3"

Azu::CQL.configure do |config|
  config.cache.on = true            # CQL turns its cache on by default only in development
  config.cache.request_cache = true # already the default once the cache is on
end

AppDB = Azu::CQL.schema(:app, "sqlite3://./db/app.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end
end

struct UsersResponse
  include Azu::Response

  def initialize(@names : Array(String))
  end

  def render
    @names.to_json
  end
end

struct ListUsers
  include Azu::Endpoint(Azu::Request, UsersResponse)

  get "/users"

  def call : UsersResponse
    names = AppDB.query.from(:users).select(:name).all(String)
    if stats = Azu::CQL.request_cache_stats
      Log.info { "#{stats.request_id}: #{stats.repeated} of #{stats.queries} queries were repeats" }
    end
    UsersResponse.new(names)
  end
end

app = Azu::App.new
app.routes { endpoint ListUsers }
handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::CQL::Middleware.new(AppDB, query_cache: true),
] of HTTP::Handler
server = app.server(handlers)
```

`Azu::CQL.request_cache_stats` returns an `Azu::CQL::RequestCacheStats` (`request_id`, `queries`, `repeated`,
`distinct`, so `queries == distinct + repeated`) while a `query_cache: true` request is being served, and `nil`
otherwise: outside a request, with the option off, or when CQL's cache or its request cache is off. Nothing is added
to the response.

* It is a diagnostic, not a cache: CQL records which statements ran and stores no rows, so nothing gets faster.
* The tracker sits inside the request scope and outside the transaction, so it ends however the request ends: a
  commit, a rollback, an exception.
* **Concurrent requests share the counters for now.** CQL keeps one request query cache for the whole process, so
  requests served at the same time add to each other's counts, and a request that starts forgets the statements of
  the ones in flight. The numbers are exact when one request runs at a time (development, a spec); Azu keeps them
  per request as soon as CQL scopes that state per fiber, with no change on your side.

## Behavior

### One validation vocabulary

CQL models and Azu requests use the same macro shape, `validate attribute, predicate: value, message: "..."`, and
the same names for the common predicates, so a rule copies between them:

| Predicate | Azu request (schema shard) | CQL model |
| --- | --- | --- |
| `presence`, `required`, `eq`, `in`, `exclude`, `match`, `size` (Int or Range) | yes | yes |
| `gt`, `gte`, `lt`, `lte` (numbers, `Time`) | yes | yes |
| `confirmation`, `accept` | no | yes |
| `message:` | one message for the attribute | one message for the attribute |

Differences that cannot be reconciled without changing the shards (the schema shard has no `confirmation` or
`accept`, and neither side has validation contexts: CQL's `validate` accepts `on:`, but a model that uses it does not
compile; the schema shard's `gt`/`gte`/`lt`/`lte` take `Int`, `Float` and `Time`): CQL predicates return false for `nil` (so a
nilable attribute fails `size`/`match` instead of raising), the schema shard's do not (use a non-nilable request
field); and `{min:, max:}` size options exist in neither, use a Range (`size: 2..50`). Both report errors as
`{field : Symbol, message : String}`.

Because of that, one adapter serves both:

* `model.valid_or_422!` runs the model's validations and returns the model, or raises `Azu::Response::ValidationError`
  (422, a problem document, `application/problem+json` when the client's `Accept` names it and `application/json` otherwise, `errors` keyed by field). Raise it from an endpoint, or let the `Rescuer` render it.
* `Azu::CQL.unprocessable(errors)` builds that error from any enumerable of errors, and from the exceptions CQL raises
  itself (`CQL::RecordInvalid`, `CQL::ValidationError`, and the validation error `save` raises).

## See also

- [Database dashboard](../database-dashboard.md)
- [CQL API](../database/cql-api.md)
- [Handle transactions](../../how-to/database/handle-transactions.md)
- [Request](request.md)
