# Getting Started

## Environment Variables

```shell
export CRYSTAL_ENV=development
export CRYSTAL_LOG_SOURCES="*"
export CRYSTAL_LOG_LEVEL=DEBUG
export PORT=4000
export PORT_REUSE=false
export HOST=0.0.0.0
```

## Define

```crystal
require "azu"

module ExampleApp
  include Azu
end
```

### Azu::Configuration

Learn more about [Azu::Configuration][]

```crystal
 Azu.configure do |c|
   c.port = 4000
   c.host = localhost
   c.port_reuse = true
   c.log = Log.for("My Awesome App")
   c.env = Environment::Development
   c.template.path = "./templates"
   c.etemplate.error_path = "./error_template"
 end
```

### Azu::Pipeline

```crystal
ExampleApp::Pipeline[:web] = [
  ExampleApp::Handler::Logger.new,
]
```

Learn more about [Azu::Pipeline][]

### Azu::Router

Define a `src/routes.cr`.

Learn more about [Azu::Router][]

```crystal
ExampleApp.router do
  # Define root endpoint
  root :web, ExampleApp::IndexEndpoint

  # Define Websockets 
  ws "/hi", ExampleApp::ExampleChannel

  # Group Routes by pipelines and path
  routes :web, "/test" do
    get "/hello", ExampleApp::IndexEndpoint
  end
end
```

### Azu::Endpoint

Azu Endpoints are compose of a Request and Response objects, enabling strict typing. 

Read more about [Azu::Endpoint][]

```crystal
module ExampleApp
  class IndexEndpoint 
    # Type Safe Endpoints
    include Azu::Endpoint(IndexRequest, IndexResponse)

    def call
      Azu::BadRequest.new(errors: req.errors.messages) unless request.valid?

      header "Custom", "Fake custom header"
      status 300

      # ...call to domain layer...
      
      IndexPage.new params.query["name"].as(String)
    rescue ex
      raise Azu::BadRequest.from_exception(ex)
    end

    # Create a request wrapper
    def index_request
      IndexRequest.new params
    end
  end
end
```

### Azu::Request

Azu requests are define by either defining a `struct` or `class` that includes the `Azu::Request` module. 

Read more about [Azu::Request][]

```crystal
module ExampleApp
  class IndexRequest
    # Defines this class as an Azu::Request 
    include Azu::Request

    # Defines your request object expected properties 
    # (query, form, path) macros are available
    query name : String, 
      message: "Param name must be string.", 
      presence: true

    # Without type safe params
    def name
      params.query["name"]
    end
  end
end
```

### Azu::Response

Azu responses are define by including one of the response types `Html`, `Error`, `Json`, `Text`, `Xml`. 

Read more about [Azu::Response][]

```crystal
module ExampleApp
  class IndexPage
    # Enables HTML Responses
    include Azu::Html
    
    def initialize(@name : String)
    end

    # Define HTML method for HTML Response
    def html
      # Uss built in html builder for folks 
      # who enjoy html as code vs templates
      doctype
      body do
        a(href: "http://crystal-lang.org") do
          text "#{@name} is awesome"
        end
      end
    end
  end
end
```

### Starts Server

```crystal
ExampleApp.start
```