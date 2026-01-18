# Content Negotiation

Content negotiation in Azu allows your API to serve different content types based on client preferences. With support for multiple formats, automatic content type detection, and flexible response handling, content negotiation makes your API more versatile and user-friendly.

## What is Content Negotiation?

Content negotiation in Azu provides:

- **Multiple Formats**: Support for JSON, XML, HTML, and custom formats
- **Automatic Detection**: Detect client preferences from headers
- **Flexible Responses**: Serve different content types for the same endpoint
- **Format Validation**: Validate content types and handle errors
- **Custom Serializers**: Implement custom serialization logic

## Basic Content Negotiation

### Accept Header Detection

```crystal
class ContentNegotiationEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/api/data"

  def call : Azu::Response::Text
    # Detect client preferences
    accept_header = context.request.headers["Accept"]?
    content_type = determine_content_type(accept_header)

    # Set response content type
    context.response.headers["Content-Type"] = content_type

    # Generate response based on content type
    case content_type
    when "application/json"
      generate_json_response
    when "application/xml"
      generate_xml_response
    when "text/html"
      generate_html_response
    else
      generate_json_response  # Default to JSON
    end
  end

  private def determine_content_type(accept_header : String?) : String
    return "application/json" unless accept_header

    # Parse Accept header
    preferences = parse_accept_header(accept_header)

    # Find best match
    if preferences.includes?("application/json")
      "application/json"
    elsif preferences.includes?("application/xml")
      "application/xml"
    elsif preferences.includes?("text/html")
      "text/html"
    else
      "application/json"  # Default
    end
  end

  private def parse_accept_header(accept_header : String) : Array(String)
    accept_header.split(",").map(&.strip)
  end
end
```

### Content Type Validation

```crystal
class ContentTypeValidator
  def self.validate_content_type(content_type : String) : Bool
    valid_types = [
      "application/json",
      "application/xml",
      "text/html",
      "text/plain",
      "application/x-www-form-urlencoded",
      "multipart/form-data"
    ]

    valid_types.includes?(content_type)
  end

  def self.validate_accept_header(accept_header : String) : Bool
    # Validate Accept header format
    accept_header.split(",").all? do |type|
      type.strip.match(/\A[a-zA-Z0-9\-\/]+\z/)
    end
  end
end
```

## Multiple Format Support

### JSON Response

```crystal
class JsonResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any))
  end

  def render
    @data.to_json
  end
end
```

### XML Response

```crystal
class XmlResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any))
  end

  def render
    generate_xml(@data)
  end

  private def generate_xml(data : Hash(String, JSON::Any)) : String
    xml = String.build do |str|
      str << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      str << "<response>\n"

      data.each do |key, value|
        str << "  <#{key}>#{escape_xml(value.to_s)}</#{key}>\n"
      end

      str << "</response>"
    end

    xml
  end

  private def escape_xml(text : String) : String
    text.gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("\"", "&quot;")
        .gsub("'", "&#39;")
  end
end
```

### HTML Response

```crystal
class HtmlResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@data : Hash(String, JSON::Any), @template : String = "api/data.html")
  end

  def render
    view @template, @data
  end
end
```

## Content Negotiation Middleware

### Content Negotiation Middleware

```crystal
class ContentNegotiationMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # Detect content type from request
    content_type = detect_request_content_type(context)

    # Set context for use in endpoints
    context.set("request_content_type", content_type)

    # Process request
    call_next(context)

    # Negotiate response content type
    negotiate_response_content_type(context)
  end

  private def detect_request_content_type(context : HTTP::Server::Context) : String
    content_type = context.request.headers["Content-Type"]?
    return "application/json" unless content_type

    # Extract main content type
    content_type.split(";").first.strip
  end

  private def negotiate_response_content_type(context : HTTP::Server::Context)
    # Get client preferences
    accept_header = context.request.headers["Accept"]?
    preferred_type = determine_preferred_type(accept_header)

    # Set response content type
    context.response.headers["Content-Type"] = preferred_type
  end

  private def determine_preferred_type(accept_header : String?) : String
    return "application/json" unless accept_header

    # Parse quality values
    preferences = parse_accept_header_with_quality(accept_header)

    # Find best match
    preferences.max_by { |_, quality| quality }?.try(&.first) || "application/json"
  end

  private def parse_accept_header_with_quality(accept_header : String) : Array({String, Float64})
    accept_header.split(",").map do |type|
      if type.includes?(";q=")
        type_part, quality_part = type.split(";q=", 2)
        quality = quality_part.to_f
        {type_part.strip, quality}
      else
        {type.strip, 1.0}
    end
  end
end
```

## Format Handlers

### JSON Handler

```crystal
class JsonHandler
  def self.serialize(data : Hash(String, JSON::Any)) : String
    data.to_json
  end

  def self.deserialize(json : String) : Hash(String, JSON::Any)
    JSON.parse(json).as_h
  end

  def self.validate(json : String) : Bool
    begin
      JSON.parse(json)
      true
    rescue
      false
    end
  end
end
```

### XML Handler

```crystal
class XmlHandler
  def self.serialize(data : Hash(String, JSON::Any)) : String
    generate_xml(data)
  end

  def self.deserialize(xml : String) : Hash(String, JSON::Any)
    parse_xml(xml)
  end

  def self.validate(xml : String) : Bool
    begin
      parse_xml(xml)
      true
    rescue
      false
    end
  end

  private def self.generate_xml(data : Hash(String, JSON::Any)) : String
    # Implement XML generation
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<response>#{data.to_json}</response>"
  end

  private def self.parse_xml(xml : String) : Hash(String, JSON::Any)
    # Implement XML parsing
    # This would use an XML parsing library
    {} of String => JSON::Any
  end
end
```

### HTML Handler

```crystal
class HtmlHandler
  def self.serialize(data : Hash(String, JSON::Any), template : String) : String
    # Render HTML template
    render_template(template, data)
  end

  def self.deserialize(html : String) : Hash(String, JSON::Any)
    # Extract data from HTML
    extract_data_from_html(html)
  end

  def self.validate(html : String) : Bool
    # Validate HTML
    validate_html_structure(html)
  end

  private def self.render_template(template : String, data : Hash(String, JSON::Any)) : String
    # Implement template rendering
    # This would use a template engine
    template
  end

  private def self.extract_data_from_html(html : String) : Hash(String, JSON::Any)
    # Extract data from HTML
    # This would parse HTML and extract data
    {} of String => JSON::Any
  end

  private def self.validate_html_structure(html : String) : Bool
    # Validate HTML structure
    # This would use an HTML validator
    true
  end
end
```

## Custom Format Support

### Custom Format Handler

```crystal
class CustomFormatHandler
  def self.serialize(data : Hash(String, JSON::Any)) : String
    # Implement custom serialization
    data.map do |key, value|
      "#{key}: #{value}"
    end.join("\n")
  end

  def self.deserialize(content : String) : Hash(String, JSON::Any)
    # Implement custom deserialization
    result = {} of String => JSON::Any

    content.each_line do |line|
      if line.includes?(":")
        key, value = line.split(":", 2)
        result[key.strip] = JSON::Any.new(value.strip)
      end
    end

    result
  end

  def self.validate(content : String) : Bool
    # Validate custom format
    content.lines.all? { |line| line.includes?(":") }
  end
end
```

### Format Registry

```crystal
class FormatRegistry
  @@handlers = {} of String => FormatHandler

  def self.register(content_type : String, handler : FormatHandler)
    @@handlers[content_type] = handler
  end

  def self.get_handler(content_type : String) : FormatHandler?
    @@handlers[content_type]?
  end

  def self.supported_types : Array(String)
    @@handlers.keys
  end
end

# Register format handlers
FormatRegistry.register("application/json", JsonHandler.new)
FormatRegistry.register("application/xml", XmlHandler.new)
FormatRegistry.register("text/html", HtmlHandler.new)
FormatRegistry.register("text/custom", CustomFormatHandler.new)
```

## Content Negotiation in Endpoints

### Flexible Endpoint

```crystal
class FlexibleEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/api/flexible"

  def call : Azu::Response::Text
    # Get client preferences
    accept_header = context.request.headers["Accept"]?
    content_type = negotiate_content_type(accept_header)

    # Set response content type
    context.response.headers["Content-Type"] = content_type

    # Generate response
    response_data = generate_response_data
    serialized_response = serialize_response(response_data, content_type)

    Azu::Response::Text.new(serialized_response)
  end

  private def negotiate_content_type(accept_header : String?) : String
    return "application/json" unless accept_header

    # Parse preferences
    preferences = parse_accept_header(accept_header)

    # Find best match
    if preferences.includes?("application/json")
      "application/json"
    elsif preferences.includes?("application/xml")
      "application/xml"
    elsif preferences.includes?("text/html")
      "text/html"
    else
      "application/json"
    end
  end

  private def serialize_response(data : Hash(String, JSON::Any), content_type : String) : String
    case content_type
    when "application/json"
      JsonHandler.serialize(data)
    when "application/xml"
      XmlHandler.serialize(data)
    when "text/html"
      HtmlHandler.serialize(data, "api/flexible.html")
    else
      JsonHandler.serialize(data)
    end
  end
end
```

### Multi-Format Endpoint

```crystal
class MultiFormatEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/api/multi"

  def call : Azu::Response::Text
    # Get client preferences
    accept_header = context.request.headers["Accept"]?
    content_type = determine_content_type(accept_header)

    # Set response content type
    context.response.headers["Content-Type"] = content_type

    # Generate response based on content type
    response = case content_type
    when "application/json"
      generate_json_response
    when "application/xml"
      generate_xml_response
    when "text/html"
      generate_html_response
    else
      generate_json_response
    end

    Azu::Response::Text.new(response)
  end

  private def generate_json_response : String
    {
      "message" => "Hello, World!",
      "timestamp" => Time.utc.to_rfc3339,
      "format" => "json"
    }.to_json
  end

  private def generate_xml_response : String
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<response>\n" +
    "  <message>Hello, World!</message>\n" +
    "  <timestamp>#{Time.utc.to_rfc3339}</timestamp>\n" +
    "  <format>xml</format>\n" +
    "</response>"
  end

  private def generate_html_response : String
    "<!DOCTYPE html>\n" +
    "<html>\n" +
    "<head><title>API Response</title></head>\n" +
    "<body>\n" +
    "  <h1>Hello, World!</h1>\n" +
    "  <p>Timestamp: #{Time.utc.to_rfc3339}</p>\n" +
    "  <p>Format: HTML</p>\n" +
    "</body>\n" +
    "</html>"
  end
end
```

## Error Handling

### Content Negotiation Errors

```crystal
class ContentNegotiationError < Exception
  def initialize(message : String, @content_type : String? = nil)
    super(message)
  end
end

class ContentNegotiationErrorHandler
  def self.handle_unsupported_format(content_type : String) : Azu::Response::Text
    error_response = {
      "error" => "Unsupported Content Type",
      "message" => "The requested content type '#{content_type}' is not supported",
      "supported_types" => ["application/json", "application/xml", "text/html"],
      "timestamp" => Time.utc.to_rfc3339
    }

    Azu::Response::Text.new(error_response.to_json)
  end

  def self.handle_parsing_error(content_type : String, error : Exception) : Azu::Response::Text
    error_response = {
      "error" => "Content Parsing Error",
      "message" => "Failed to parse #{content_type} content",
      "details" => error.message,
      "timestamp" => Time.utc.to_rfc3339
    }

    Azu::Response::Text.new(error_response.to_json)
  end
end
```

## Testing Content Negotiation

### Unit Testing

```crystal
require "spec"

describe ContentNegotiationEndpoint do
  it "handles JSON requests" do
    context = create_test_context(headers: {"Accept" => "application/json"})
    endpoint = ContentNegotiationEndpoint.new

    response = endpoint.call

    response.content_type.should eq("application/json")
    JSON.parse(response.body).should be_a(JSON::Any)
  end

  it "handles XML requests" do
    context = create_test_context(headers: {"Accept" => "application/xml"})
    endpoint = ContentNegotiationEndpoint.new

    response = endpoint.call

    response.content_type.should eq("application/xml")
    response.body.should contain("<?xml")
  end

  it "handles HTML requests" do
    context = create_test_context(headers: {"Accept" => "text/html"})
    endpoint = ContentNegotiationEndpoint.new

    response = endpoint.call

    response.content_type.should eq("text/html")
    response.body.should contain("<html>")
  end
end
```

### Integration Testing

```crystal
describe "Content Negotiation Integration" do
  it "negotiates content type based on Accept header" do
    # Test JSON negotiation
    response = make_request("/api/data", headers: {"Accept" => "application/json"})
    response.headers["Content-Type"].should eq("application/json")

    # Test XML negotiation
    response = make_request("/api/data", headers: {"Accept" => "application/xml"})
    response.headers["Content-Type"].should eq("application/xml")

    # Test HTML negotiation
    response = make_request("/api/data", headers: {"Accept" => "text/html"})
    response.headers["Content-Type"].should eq("text/html")
  end

  it "handles quality values in Accept header" do
    response = make_request("/api/data", headers: {
      "Accept" => "application/json;q=0.8, application/xml;q=0.9, text/html;q=1.0"
    })

    # Should prefer HTML due to higher quality value
    response.headers["Content-Type"].should eq("text/html")
  end
end
```

## Best Practices

### 1. Use Appropriate Content Types

```crystal
# Good: Appropriate content types
case content_type
when "application/json"
  generate_json_response
when "application/xml"
  generate_xml_response
when "text/html"
  generate_html_response
end

# Avoid: Wrong content types
case content_type
when "json"  # Should be "application/json"
  generate_json_response
when "xml"   # Should be "application/xml"
  generate_xml_response
end
```

### 2. Handle Content Negotiation Errors

```crystal
# Good: Handle errors gracefully
def negotiate_content_type(accept_header : String?) : String
  return "application/json" unless accept_header

  begin
    preferences = parse_accept_header(accept_header)
    find_best_match(preferences)
  rescue
    "application/json"  # Fallback to default
  end
end

# Avoid: Ignoring errors
def negotiate_content_type(accept_header : String?) : String
  preferences = parse_accept_header(accept_header)  # Can raise exception
  find_best_match(preferences)
end
```

### 3. Validate Content Types

```crystal
# Good: Validate content types
def validate_content_type(content_type : String) : Bool
  valid_types = ["application/json", "application/xml", "text/html"]
  valid_types.includes?(content_type)
end

# Avoid: No validation
def process_content_type(content_type : String)
  # No validation - can cause errors
end
```

### 4. Use Quality Values

```crystal
# Good: Handle quality values
def parse_accept_header(accept_header : String) : Array({String, Float64})
  accept_header.split(",").map do |type|
    if type.includes?(";q=")
      type_part, quality_part = type.split(";q=", 2)
      {type_part.strip, quality_part.to_f}
    else
      {type.strip, 1.0}
    end
  end
end

# Avoid: Ignoring quality values
def parse_accept_header(accept_header : String) : Array(String)
  accept_header.split(",").map(&.strip)  # Ignores quality values
end
```

### 5. Provide Fallbacks

```crystal
# Good: Provide fallbacks
def negotiate_content_type(accept_header : String?) : String
  return "application/json" unless accept_header

  preferences = parse_accept_header(accept_header)

  if preferences.includes?("application/json")
    "application/json"
  elsif preferences.includes?("application/xml")
    "application/xml"
  else
    "application/json"  # Fallback to default
  end
end

# Avoid: No fallbacks
def negotiate_content_type(accept_header : String?) : String
  preferences = parse_accept_header(accept_header)
  find_best_match(preferences)  # Can return nil
end
```

## Next Steps

Now that you understand content negotiation:

1. **[API Design](../features/api-design.md)** - Design flexible APIs
2. **[Testing](../testing.md)** - Test content negotiation
3. **[Performance](performance.md)** - Optimize content negotiation
4. **[Deployment](../deployment/production.md)** - Deploy with content negotiation
5. **[Security](../advanced/security.md)** - Implement secure content negotiation

---

_Content negotiation in Azu provides flexible, client-aware API responses. With support for multiple formats, automatic detection, and error handling, it makes your API more versatile and user-friendly._
