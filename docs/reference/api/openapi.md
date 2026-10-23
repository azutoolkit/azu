# OpenAPI Reference

`Azu::OpenAPI` generates an [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0) document from the
`Endpoint(Request, Response)` contracts of an app and can serve it. The request and response types are
the source of truth, so the document cannot drift from the code. It is part of `require "azu"`; nothing
is built until you ask for the document.

## Quick start

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

# Serve it at GET /openapi.json
handler = Azu::OpenAPI::Handler.new(app, info: info)
server = app.server([handler] of HTTP::Handler)
```

## What the document contains

`Azu::OpenAPI.document(app, info, servers = [])` returns an `Azu::OpenAPI::Document`. `#to_json` gives the
JSON text (`pretty: true` indents it) and `#to_h` the structure. Keys are sorted, so the same app yields
the same bytes and a document can be compared or committed.

- **Paths.** One operation per route that leads to an `Azu::Endpoint`. `:id` and `*path` become `{id}` and
  `{path}` and are declared as required path parameters, typed from the request field of the same name
  (a string when there is none). Routes inside `scope` carry the scope prefix. Apps added with `mount`
  are included below their mount path, at any depth. The `HEAD` and `OPTIONS` routes registered for a `GET`
  are not listed again.
- **`operationId`** is the endpoint's type name with `::` written as `.`. If one endpoint is routed more
  than once, later ids get a number suffix. **`tags`** hold the namespace the endpoint is declared in:
  `Shop::Users::ShowEndpoint` is tagged `Users`.
- **Request fields.** For `GET`, `DELETE`, `HEAD`, `OPTIONS` and `TRACE` the fields of the request
  that are not in the path are query parameters. For `POST`, `PUT` and `PATCH` they are a `requestBody`
  offered as `application/json` and as `application/x-www-form-urlencoded`, because Azu parses both.
- **Response.** If the response type includes `JSON::Serializable` the `200` response carries its schema
  as `application/json`.
- **Errors.** An operation with request fields adds `400` and `422`; one with a path parameter adds `404`.
  They reference shared `components`: `Azu.ValidationProblem` is the RFC 7807 `application/problem+json`
  body that `Response::ValidationError` writes, and `Azu.Error` is the body the other `Response::Error`
  classes write for a client that accepts JSON.
- **Components.** Every `JSON::Serializable` type becomes a named schema under `components.schemas`, named
  after its type (`Shop::Address` is `Shop.Address`) and referenced with `$ref`. Recursive types work.
- Security schemes, summaries and descriptions are left out: Azu cannot read them from the code.

## Types

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

## Validations become constraints

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

Custom validators added with `Schema::Validation.use` are code and cannot be described. Regular
expressions are passed through as written: Crystal's PCRE2 syntax is close to, but not the same as, the
ECMA-262 dialect JSON Schema asks for.

## Serving the document

`Azu::OpenAPI::Handler.new(app, info:, path: "/openapi.json", servers: [])` is an opt-in `HTTP::Handler`
like `Handler::HealthCheck`: it answers `GET` and `HEAD` at `path` with JSON and passes every other
request on. The document is built by the first request and kept, so routes added after that do not
show up. There is no documentation UI; point Swagger UI, Redoc or any other tool at the URL.

## Limits

- A response that is not `JSON::Serializable` has no schema, and neither has a request that is the bare
  `Azu::Request`: nothing says what they carry. Wrong or missing is better than invented.
- A `render` that does not write the type's own `to_json` makes the document wrong; Azu cannot check it.
- Hand written `Routable` and `HTTP::Handler` routes have no operation and are left out. So are WebSocket
  channels.
- Only the default error format is described. With `error_format = Legacy`, the 422 body differs.
- An explicit JSON `null` for a nilable field is accepted by Azu but not advertised in the schema.
- Nested objects in query parameters are described by their schema; how a client encodes them is up to it.
- The routes are read when the document is built. Endpoints declared with the verb macros (`get "/path"`
  inside an endpoint) are registered on `Azu::App.default`, so pass that app.

The generator in the `azu` CLI (`azu openapi:export`) reads source files with regular expressions. This
module reads the compiler's types instead and supersedes it; the CLI is not changed here.
