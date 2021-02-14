# Getting Started

## Environment Variables

```shell
export CRYSTAL_ENV=development
export CRYSTAL_LOG_SOURCES="*"
export CRYSTAL_LOG_LEVEL=DEBUG
export CRYSTAL_WORKERS=8
export PORT=4000
export PORT_REUSE=true
export HOST=0.0.0.0
export TEMPLATES_PATH=
export ERROR_TEMPLATE=
```

## Define

```crystal
require "azu"

module ExampleApp
  include Azu
end
```

### Configuration

Learn more about [Configuration][]

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


### Endpoint

Azu Endpoints are compose of a Request and Response objects, enabling strict typing. 

Read more about [Endpoint][]

```crystal
module ExampleApp
  class IndexEndpoint 
    # Type Safe Endpoints
    include Endpoint(IndexRequest, IndexResponse)

    # Define your routes
    get "/hello", accept: "text/plain", content_type: "text/html"

    def call
      # Built in Error Types
      BadRequest.new(errors: req.errors.messages) unless request.valid?

      header "Custom", "Fake custom header"
      status 300

      # ...call to domain layer...
      
      IndexPage.new params.query["name"].as(String)
    rescue ex
      BadRequest.from_exception(ex)
    end

    # Create a request wrapper
    def index_request
      IndexRequest.new params
    end
  end
end
```

### Request

Azu requests are contracts that you can validate 

Read more about [Request][]

```crystal
module ExampleApp
  struct IndexRequest
    # Request Type
    include Request

    # Defines your request object expected properties 
    # (query, form, path) macros are available
    query name : String, 
      message: "Param name must be string.", 
      presence: true

    # Without type safe params you can access params
    # params.query["name"] params is also available on Endpoints
    def name
      params.query["name"]
    end
  end
end
```

### Response

Azu responses are define by including one of the response types `Html`, `Error`, `Json`, `Text`, `Xml`. 

Read more about [Response][]

```crystal
module ExampleApp
  class IndexPage
    # Enables HTML Responses
    include Html
    
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