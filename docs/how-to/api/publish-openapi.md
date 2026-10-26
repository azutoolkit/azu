---
description: "Serve your app's OpenAPI document, show it in Swagger UI, keep a copy in git that CI checks, and add what Azu cannot infer."
---

# Publish your OpenAPI document

Azu builds an OpenAPI 3.1 document from the request and response types of your endpoints; what it contains is
listed on [OpenAPI](../../reference/api/openapi.md). The examples use this app:

<!-- prelude -->
```crystal
require "azu"

module MyApp
  include Azu
end

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  validate name, presence: true, size: 2..50
  validate email, match: /@/

  def initialize(@name = "", @email = "")
  end
end

struct UserResponse
  include Azu::Response
  include JSON::Serializable

  getter name : String

  def initialize(@name : String)
  end

  def render
    to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/api/users"

  def call : UserResponse
    content_type "application/json"
    UserResponse.new(create_user_request.name)
  end
end

OPENAPI_INFO = Azu::OpenAPI::Info.new("Shop API", "1.0.0")
```

## Serve the document

Add `Azu::OpenAPI::Handler` after the default handlers, in development only:

```crystal
handlers = Azu::App.default.default_handlers
handlers << Azu::OpenAPI::Handler.new(Azu::App.default, info: OPENAPI_INFO) if MyApp.env.development?

MyApp.start handlers
```

`GET /openapi.json` now answers `200` with the document as `application/json`, and `HEAD` with its
`Content-Length`. Coming after `RequestId`, `Logger`, `Rescuer` and `SecurityHeaders`, the response carries a request
id, a log line and the security headers. Other requests pass on to the router. The document is built by the first
request and kept, so a restart picks up new routes.

To publish the document in every environment, drop the `if`. When the API is not public, put the handler after
your authentication handler: the document lists every route, its parameters and its validation rules (see
[Securing the document](../../reference/api/openapi.md#securing-the-document)).

## Add a Swagger UI page

Serve an HTML page that loads Swagger UI from a CDN and points it at the document:

```crystal
SWAGGER_UI = <<-HTML
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Shop API</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css">
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>
    <script>SwaggerUIBundle({url: "/openapi.json", dom_id: "#swagger-ui"});</script>
  </body>
  </html>
  HTML

DOCS_POLICY = "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " \
              "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data:"

struct SwaggerUIPage
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/html; charset=utf-8"
    context.response.headers["Content-Security-Policy"] = DOCS_POLICY
    context.response << SWAGGER_UI
    context
  end
end

Azu::App.default.routes { get "/docs", SwaggerUIPage.new } if MyApp.env.development?
```

`GET /docs` shows the operations of `/openapi.json`. The page is an `Azu::Routable`, not an `Azu::Endpoint`: an
endpoint would be listed in the document as one more operation, while a hand-written route is left out. The page and
the document share an origin, so no CORS is needed.

`SecurityHeaders` sends no `Content-Security-Policy` unless you build it with `content_security_policy:`. If you do,
your policy would also block the CDN and the inline script of this page. `SecurityHeaders` writes its headers before
the route runs, so the header the page sets replaces the app's policy for `/docs` only.

## Keep the document in git

A committed copy shows in review what a change does to the API. Keep the files that declare your endpoints loadable
without the file that calls `MyApp.start`, then write the document from a script:

<!-- skip -->
{% code title="scripts/openapi.cr" %}
```crystal
require "../src/app" # declares the endpoints; src/server.cr requires it and calls MyApp.start

document = Azu::OpenAPI.document(Azu::App.default, Azu::OpenAPI::Info.new("Shop API", "1.0.0"))
File.write("openapi.json", document.to_json(pretty: true) + "\n")
```
{% endcode %}

Commit `openapi.json`, and fail CI when it no longer matches the code:

```bash
crystal run scripts/openapi.cr
git diff --exit-code openapi.json
```

Keys are sorted and nothing in the document depends on the time or the machine, so the file changes only when a
route or a contract does.

## Add what Azu does not generate

Summaries, descriptions and security schemes are not in the code, so Azu leaves them out. `Document#to_h` returns the
document's own map; edit it before you serve or write the document:

<!-- prelude -->
```crystal
document = Azu::OpenAPI.document(Azu::App.default, OPENAPI_INFO)
root = document.to_h

create = root["paths"].as(Azu::OpenAPI::Map)["/api/users"].as(Azu::OpenAPI::Map)["post"].as(Azu::OpenAPI::Map)
create["summary"] = "Create a user"

components = (root["components"] ||= Azu::OpenAPI::Map.new).as(Azu::OpenAPI::Map)
components["securitySchemes"] = Azu::OpenAPI::Map{"bearer" => Azu::OpenAPI::Map{"type" => "http", "scheme" => "bearer"}}
root["security"] = [Azu::OpenAPI::Map{"bearer" => [] of Azu::OpenAPI::Value}] of Azu::OpenAPI::Value
```

`document.to_json` now includes the edits. `Azu::OpenAPI::Handler` builds a document of its own, so serve the edited
one with a handler that answers like it:

```crystal
class OpenAPIDocument
  include HTTP::Handler

  def initialize(@json : String, @path : String = "/openapi.json")
  end

  def call(context : HTTP::Server::Context)
    request = context.request
    return call_next(context) unless request.path == @path && request.method.in?("GET", "HEAD")

    context.response.content_type = "application/json"
    context.response.content_length = @json.bytesize
    context.response << @json unless request.method == "HEAD"
  end
end

handlers = Azu::App.default.default_handlers
handlers << OpenAPIDocument.new(document.to_json)

MyApp.start handlers
```

Build the document after every route is declared, as here at boot. The script above can make the same edits before it
writes the file.

## See also

- [OpenAPI](../../reference/api/openapi.md): what the document contains and what it cannot describe
- [Built-in handlers](../../reference/handlers/built-in.md): `SecurityHeaders` and `CORS`
- [Contracts](../../explanation/concepts/contracts.md)
