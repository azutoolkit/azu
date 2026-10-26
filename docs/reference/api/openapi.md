---
description: Generate an OpenAPI 3.1 document from your endpoint contracts, serve it, and know what it cannot describe.
---

# OpenAPI

`Azu::OpenAPI` builds an [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0) document from the
`Endpoint(Request, Response)` contracts of an app, and `Azu::OpenAPI::Handler` serves it. The request and response
types are the source of truth, so the document cannot drift from the code. It is part of `require "azu"`; nothing is
built until you ask for the document. It writes JSON, and with `docs:` the handler also serves a reference page of
it. It is not the `azu openapi:export` command of the Azu CLI (see [Limits](#limits)).

```crystal
require "azu"

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32 = 0

  validate name, presence: true, size: 2..50
  validate email, match: /@/
  validate age, gte: 0

  def initialize(@name = "", @email = "", @age = 0)
  end
end

struct UserResponse
  include Azu::Response
  include JSON::Serializable

  property name : String

  def initialize(@name : String = "")
  end

  def render
    to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  def call : UserResponse
    UserResponse.new(create_user_request.name)
  end
end

app = Azu::App.new
app.routes do
  scope "/api" do
    post "/users", CreateUserEndpoint
  end
end

info = Azu::OpenAPI::Info.new("Shop API", "1.0.0")
document = Azu::OpenAPI.document(app, info)
puts document.to_json(pretty: true)

# Serve it at GET /openapi.json, and a reference page at GET /docs
handler = Azu::OpenAPI::Handler.new(app, info: info, docs: "/docs")
server = app.server([*app.default_handlers, handler] of HTTP::Handler)
```

## API

| Signature | Returns | Notes |
| --- | --- | --- |
| `Azu::OpenAPI.document(app : App, info : Info, servers : Array(Server) = [] of Server)` | `Document` | A snapshot of the routes `app` has when it is called, mounted apps included |
| `Document#to_json(pretty : Bool = false)` | `String` | Keys sorted, so the same app yields the same bytes; `pretty` indents by two spaces |
| `Document#to_h` | `OpenAPI::Map` | The document's own map, not a copy: a change to it shows in `to_json` |
| `Document.new(root : Map)` | `Document` | A document around a map |
| `Azu::OpenAPI.encode(value : Value, pretty : Bool = false)` | `String` | JSON with sorted keys, for any `Value` |
| `Azu::OpenAPI::Info.new(title : String, version : String, description : String? = nil)` | `Info` | The `info` object |
| `Azu::OpenAPI::Server.new(url : String, description : String? = nil)` | `Server` | One entry of `servers`; none are written when the array is empty |

`Azu::OpenAPI::Map` is `Hash(String, Value)`, and `Azu::OpenAPI::Value` is
`String | Int64 | Float64 | Bool | Nil | Array(Value) | Hash(String, Value)`.

`Azu::OpenAPI::Handler.new(app, *, info, path = "/openapi.json", servers = [] of Server, docs = nil)`:

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `app` | `App` | | The app the document describes |
| `info` | `Info` | | The `info` object |
| `path` | `String` | `"/openapi.json"` | Where the document is served; a trailing slash is dropped, and `"/"` serves it at the root |
| `servers` | `Array(Server)` | `[] of Server` | The `servers` entries |
| `docs` | `String?` | `nil` | Where the HTML reference page is served (off when nil); a trailing slash is dropped. The same path as `path` raises `ArgumentError` |

## Behavior

### What the document contains

- **Paths.** One operation per route that leads to an `Azu::Endpoint`. `:id` and `*path` become `{id}` and
  `{path}` and are declared as required path parameters, typed from the request field of the same name
  (a string when there is none). Routes inside `scope` carry the scope prefix. Apps added with `mount`
  are included below their mount path, at any depth. The `HEAD` route registered with a `GET` is not listed
  again; an `options` route you declare is listed as an `options` operation.
- **`operationId`** is the endpoint's type name with `::` written as `.`. If one endpoint is routed more
  than once, later ids get a number suffix. **`tags`** hold the namespace the endpoint is declared in:
  `Shop::Users::ShowEndpoint` is tagged `Users`.
- **Request fields.** For `GET`, `DELETE`, `HEAD`, `OPTIONS` and `TRACE` the fields of the request
  that are not in the path are query parameters. For `POST`, `PUT` and `PATCH` they are a `requestBody`
  offered as `application/json` and as `application/x-www-form-urlencoded`, because Azu parses both.
  The two differ where Azu's parsing does. A JSON body is read alone: the path and the query string are
  not added to it (they only replace a key the body already has, see [Params](endpoint.md#params)), so a field named
  like a path parameter is also in the JSON schema (and required there if the request requires it) as well as being
  declared as a path parameter. A form is read together with the path and the query string, so the form schema leaves
  path-named fields out. The keys follow the parser: `@[JSON::Field(key:)]` renames a field in the JSON body only;
  query parameters and form fields always use the variable name.
- **Response.** If the response type includes `JSON::Serializable` the `200` response carries its schema
  as `application/json`. A `Response::Negotiable` lists every media type it renders, with the schema under
  `application/json` and `{"type": "string"}` under the others.
- **Errors.** An operation with request fields adds `400` and `422`; one with a path parameter adds `404`.
  They reference shared `components`: `Azu.ValidationProblem` is the RFC 7807 problem body (listed as
  `application/problem+json` and `application/json`) that `Response::ValidationError` writes, and `Azu.Error` is the
  problem body (listed as `application/problem+json` and `application/json`) the other `Response::Error` classes write
  for a client that accepts JSON (`type`, `title`, `status`, `detail`, `errors`, `error_id`, and `instance` when the
  error knows the path). The document follows the `error_format` the app has when it is built: with `Legacy` the 400,
  404 and 422 are `application/json`, and `Azu.LegacyValidationError` and `Azu.LegacyError` (the PascalCase bodies,
  `Status` being the underscored `HTTP::Status` member name) replace the problem schemas.
- **Components.** Every `JSON::Serializable` type becomes a named schema under `components.schemas`, named
  after its type (`Shop::Address` is `Shop.Address`; a generic `Page(Shop::User)` is `Page.Shop.User`, since
  component names allow only letters, digits, `.`, `-` and `_`) and referenced with `$ref`. Recursive
  types work. `operationId` uses the same naming.

### Types

| Crystal | JSON Schema |
| --- | --- |
| `String` | `string` |
| `Int32`, `Int64`, other integers | `integer` with `format` `int32` / `int64` / none |
| `Float32`, `Float64` | `number` with `format` `float` / `double` |
| `Bool` | `boolean` |
| `Time` | `string`, `date-time` |
| `UUID` | `string`, `uuid` |
| `enum` | `string` with `enum` of the members as `to_json` writes them (underscored) |
| `Array(T)`, `Set(T)` | `array` with `items` |
| `Hash(String, T)` | `object` with `additionalProperties` |
| `T?` | the schema of `T`, and the field is not required |
| `A \| B` | `anyOf` |
| `JSON::Serializable` struct or class | `$ref` to a component; `@[JSON::Field(key:, ignore:)]` is honoured |
| anything else | `{}` (allows anything) |

A field is required unless its type is nilable or it has a default value, or a `presence` or `required`
validation says it must be there.

### Validations become constraints

The options of `validate` are read from the request type:

| `validate` option | Keyword |
| --- | --- |
| `presence: true` | required, and `minLength` / `minItems` 1 |
| `required: true` | required |
| `size: 3..8`, `size: 6` | `minLength` / `maxLength` (`minItems` / `maxItems` for arrays) |
| `gt`, `gte`, `lt`, `lte` | `exclusiveMinimum`, `minimum`, `exclusiveMaximum`, `maximum` |
| `eq: v` | `const` |
| `in: [..]`, `in: 1..5` | `enum`, or `minimum` / `maximum` |
| `exclude: [..]` | `not: {enum: [..]}` |
| `match: /re/` | `pattern` |

Custom validators added with `Schema::Validation.use` are code and cannot be described, and the
validations of a generic type (`Page(T)`) are not read.

A `match` pattern is written only when it means the same in ECMA-262, the dialect JSON Schema uses:
`\A` becomes `^` and `\z` and `\Z` become `$`. A pattern with options (`/i`, `/m`, `/x`), named groups,
inline flags or other group extensions, POSIX classes (`[[:alpha:]]`) or Crystal-only escapes (`\h`,
`\R`, `\p{..}` and the like) is left out rather than written wrongly. Crystal's `^` and `$` also match at
line breaks, which an ECMA-262 pattern without the `m` flag does not, so a multi-line value can differ.

### Serving the document

`Azu::OpenAPI::Handler` is an opt-in `HTTP::Handler` like `Handler::HealthCheck`: it answers `GET` and `HEAD` at its
path with `application/json` and a `Content-Length` (no body for `HEAD`), and passes every other request on. The
document is built by the first request and kept, so routes added after that do not show up: build a new handler to
pick them up. It describes the `App` it is given, nothing else.

With `docs: "/docs"` it also answers `GET` and `HEAD` at `/docs` with an HTML page of the same document: every
operation with its parameters, request bodies and responses, then the shared schemas, linked from where they are used.
The page is rendered on the server, so it works offline and has no script and nothing loaded from elsewhere; every
value is HTML-escaped. It carries its own `Content-Security-Policy` (`default-src 'none'` and the hash of its inline
style), which replaces the app's policy for that path only. It is a reference to read, not a console: to send requests
from the browser, use Swagger UI (see [Publish your OpenAPI document](../../how-to/api/publish-openapi.md#add-a-swagger-ui-page)).

{% hint style="warning" %}
Pass the handler after the default ones, as above: a server built from `[handler]` alone has no request id, error
pages or security headers.
{% endhint %}

### Securing the document

The document is a map of your application: every route, the names of its parameters, the validation rules
and the mounted apps. Treat it like source code you would show to a client.

- Add the handler only where you mean to publish it, for example behind `config.env.development?` or a
  setting, not unconditionally in production.
- Put it after your authentication and authorisation handlers when the API is not public.
- A Swagger UI served from another origin needs CORS (`Azu::Handler::CORS`) on the document's path.

## Limits

- **Not generated:** summaries and descriptions of operations and parameters, security schemes and requirements,
  examples, and a success status other than `200` (an endpoint's status is set while it runs, so the document cannot
  know about a `201` or `204`). Azu cannot read them from the code; add them by editing `to_h` (see
  [Publish your OpenAPI document](../../how-to/api/publish-openapi.md#add-what-azu-does-not-generate)).
- **JSON only.** There is no YAML writer (`JSON.parse(document.to_json).to_yaml`, with `require "yaml"`,
  converts it and keeps the key order). The `docs:` page is read-only; for "try it out", point Swagger UI, Redoc or
  any other tool at the URL.
- A response that is not `JSON::Serializable` has no schema, and neither has a request that is the bare
  `Azu::Request`: nothing says what they carry. Wrong or missing is better than invented.
- A `render` that does not write the type's own `to_json` makes the document wrong; Azu cannot check it.
- Hand written `Routable` and `HTTP::Handler` routes have no operation and are left out. So are WebSocket
  channels.
- Query parameters of `POST`, `PUT` and `PATCH` are not described. Azu reads them only for form bodies
  (merged into the form), not for JSON ones.
- `@[JSON::Field(ignore:)]` and `@[URI::Params::Field(ignore:)]` leave a field out. A field with
  `converter:` (or JSON `root:`) is described as `{}`, since its type is not what it holds. `emit_null`
  and `ignore_serialize` are not considered.
- Nested objects in query parameters and forms use the schema of the JSON object; how a client encodes
  them (`a[b]=1`) is up to it.
- An explicit JSON `null` for a nilable field is accepted by Azu but not advertised in the schema.
- The routes are read when the document is built. Endpoints declared with the verb macros (`get "/path"`
  inside an endpoint) are registered on `Azu::App.default`, so pass that app.

{% hint style="info" %}
**`azu openapi:export` is a different generator.** The command of the [Azu CLI](https://github.com/azutoolkit/azu_cli)
(`--output`, `--format yaml|json`, `--project`, `--version`) does not compile the app: it reads
`src/endpoints/**/*_endpoint.cr` with regular expressions. It finds verb macros in structs whose name ends in
`Endpoint`, so routes declared in `routes`, `scope` or `mount` are missing; it keeps `:id` in paths instead of
`{id}`, writes a fixed `http://localhost:3000` server and reads no validations. `Azu::OpenAPI` describes the routes
the app has.
{% endhint %}

## See also

- [Publish your OpenAPI document](../../how-to/api/publish-openapi.md)
- [Endpoint](endpoint.md)
- [Request](request.md)
- [Contracts](../../explanation/concepts/contracts.md)
