# How to Return Different Formats

This guide shows you how to return JSON, HTML, text, and other response formats.

## JSON Response

Return JSON data:

```crystal
struct JsonEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/api/data"

  def call
    json({
      message: "Hello",
      timestamp: Time.utc.to_rfc3339
    })
  end
end
```

### Custom JSON Response

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email
    }.to_json
  end
end
```

## Text Response

Return plain text:

```crystal
struct TextEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/health"

  def call
    text "OK"
  end
end
```

## HTML Response

Return HTML content:

```crystal
struct HtmlEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Html)

  get "/page"

  def call
    html <<-HTML
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

```crystal
struct TemplateEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Html)
  include Azu::Templates::Renderable

  get "/users"

  def call
    view "users/index.html", {
      users: User.all,
      title: "User List"
    }
  end
end
```

## Empty Response

Return no content (204):

```crystal
struct DeleteEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)

  delete "/users/:id"

  def call
    user = User.find(params["id"].to_i64)
    user.try(&.delete)

    status 204
    Azu::Response::Empty.new
  end
end
```

## Content Negotiation

Return different formats based on Accept header:

```crystal
struct NegotiatedEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response)

  get "/data"

  def call
    data = {message: "Hello", value: 42}

    case accept_type
    when "application/json"
      json data
    when "text/html"
      html "<p>#{data[:message]}: #{data[:value]}</p>"
    when "text/plain"
      text "#{data[:message]}: #{data[:value]}"
    else
      json data  # Default to JSON
    end
  end

  private def accept_type
    headers["Accept"]?.try(&.split(",").first) || "application/json"
  end
end
```

## Setting Headers

Add custom response headers:

```crystal
def call
  response.headers["X-Custom-Header"] = "value"
  response.headers["Cache-Control"] = "max-age=3600"

  json({data: "value"})
end
```

## Redirect Response

Redirect to another URL:

```crystal
def call
  redirect_to "/new-location"
  # or
  redirect_to "/new-location", status: 301  # Permanent redirect
end
```

## File Download

Return a file for download:

```crystal
struct DownloadEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response)

  get "/download/:filename"

  def call
    filename = params["filename"]
    file_path = File.join("files", filename)

    if File.exists?(file_path)
      response.headers["Content-Type"] = "application/octet-stream"
      response.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
      response.body = File.read(file_path)
    else
      raise Azu::Response::NotFound.new("/download/#{filename}")
    end
  end
end
```

## See Also

- [Create an Endpoint](create-endpoint.md)
- [Render HTML Templates](../templates/render-html-templates.md)
