# Return different formats

This guide shows you how to return JSON, HTML, text, and other response formats.

An endpoint returns a response object, and the body is whatever the response's `render` returns. The format
is chosen by the content type the endpoint sets with `content_type`.

## JSON Response

Return JSON data:

```crystal
struct JsonResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    {
      message:   @message,
      timestamp: Time.utc.to_rfc3339,
    }.to_json
  end
end

struct JsonEndpoint
  include Azu::Endpoint(Azu::Request, JsonResponse)

  get "/api/data"

  def call : JsonResponse
    content_type "application/json"
    JsonResponse.new("Hello")
  end
end
```

### Serializing an Object

A response can include `JSON::Serializable` and render itself:

```crystal
struct User
  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email)
  end
end

struct UserResponse
  include Azu::Response
  include JSON::Serializable

  getter id : Int64
  getter name : String
  getter email : String

  def initialize(user : User)
    @id = user.id
    @name = user.name
    @email = user.email
  end

  def render
    to_json
  end
end
```

## Text Response

Return plain text:

```crystal
struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct TextEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  get "/health"

  def call : TextResponse
    content_type "text/plain"
    TextResponse.new("OK")
  end
end
```

## HTML Response

Return HTML content:

```crystal
struct HtmlResponse
  include Azu::Response

  def initialize(@html : String)
  end

  def render
    @html
  end
end

struct HtmlEndpoint
  include Azu::Endpoint(Azu::Request, HtmlResponse)

  get "/page"

  def call : HtmlResponse
    content_type "text/html"
    HtmlResponse.new <<-HTML
      <!DOCTYPE html>
      <html>
        <head><title>Page</title></head>
        <body><h1>Hello!</h1></body>
      </html>
      HTML
  end
end
```

### Using Templates

Include `Azu::Templates::Renderable` in the response and call `view` with a template name and data. Templates are
read from the configured templates path:

```crystal
struct UsersPageResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@names : Array(String))
  end

  def render
    view "users/index.html", {
      "users" => @names,
      "title" => "User List",
    }
  end
end

struct TemplateEndpoint
  include Azu::Endpoint(Azu::Request, UsersPageResponse)

  get "/users"

  def call : UsersPageResponse
    content_type "text/html"
    UsersPageResponse.new(["Ada", "Grace"])
  end
end
```

## Empty Response

Return no content (204):

```crystal
struct DeleteEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    # delete the user here

    status 204
    Azu::Response::Empty.new
  end
end
```

## Content Negotiation

Let the `Accept` header pick the format with `Azu::Response::Negotiable`. Define the `render_html`, `render_json`,
`render_xml` or `render_text` methods you need; the response sends the matching `Content-Type` and `Vary: Accept`:

```crystal
struct NegotiatedResponse
  include Azu::Response::Negotiable

  prefer :json # what a request without Accept, or with */*, gets

  def initialize(@message : String, @value : Int32)
  end

  def render_html : String
    "<p>#{HTML.escape(@message)}: #{@value}</p>"
  end

  def render_json : String
    {message: @message, value: @value}.to_json
  end

  def render_text : String
    "#{@message}: #{@value}"
  end
end

struct NegotiatedEndpoint
  include Azu::Endpoint(Azu::Request, NegotiatedResponse)

  get "/data"

  def call : NegotiatedResponse
    NegotiatedResponse.new("Hello", 42)
  end
end
```

The `q` values count: `Accept: text/html;q=0.5, text/plain` gets `Hello: 42` as `text/plain; charset=utf-8`. A
request without `Accept`, or with `*/*`, gets JSON because of `prefer :json`. A client that accepts none of the formats
(`Accept: image/png`) gets a `406` before `call` runs, and `?format=text` overrides the header. The rules are in
[Content negotiation](../../reference/api/content-negotiation.md).

Errors raised from an endpoint are negotiated for you: `Azu::Handler::Rescuer` renders them as HTML, JSON, XML
or plain text according to `Accept`.

## Setting Headers

Add custom response headers with `header key, value`:

```crystal
struct CachedResponse
  include Azu::Response

  def render
    {data: "value"}.to_json
  end
end

struct CachedEndpoint
  include Azu::Endpoint(Azu::Request, CachedResponse)

  get "/cached"

  def call : CachedResponse
    header "X-Custom-Header", "value"
    header "Cache-Control", "max-age=3600"

    content_type "application/json"
    CachedResponse.new
  end
end
```

## Redirect Response

Redirect to another URL. `redirect` sets the status and the `Location` header and returns `Azu::Response::Empty`:

```crystal
struct MovedEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/moved"

  def call : Azu::Response::Empty
    redirect to: "/new-location", status: 302 # Temporary redirect
  end
end

struct PermanentlyMovedEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/old"

  def call : Azu::Response::Empty
    redirect to: "/new-location" # 301, permanent, is the default
  end
end
```

## File Download

Return a file for download. Let the response read the file, and keep the name inside the directory with
`File.basename`:

```crystal
struct FileResponse
  include Azu::Response

  def initialize(@path : String)
  end

  def render
    File.read(@path)
  end
end

struct DownloadEndpoint
  include Azu::Endpoint(Azu::Request, FileResponse)

  get "/download/:filename"

  def call : FileResponse
    filename = File.basename(params["filename"])
    file_path = File.join("files", filename)
    raise Azu::Response::NotFound.new("/download/#{filename}") unless File.file?(file_path)

    content_type "application/octet-stream"
    header "Content-Disposition", %(attachment; filename="#{filename}")
    FileResponse.new(file_path)
  end
end
```

## See Also

- [Create an Endpoint](create-endpoint.md)
- [Render HTML Templates](../templates/render-html-templates.md)
