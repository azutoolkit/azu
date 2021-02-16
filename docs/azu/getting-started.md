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

  configure do |c|
    c.port = 4000
    c.host = localhost
    c.port_reuse = true
    c.log = Log.for("My Awesome App")
    c.env = Environment::Development
    c.template.path = "./templates"
    c.template.error_path = "./error_template"
  end
end
```

### Endpoint

Azu Endpoints are compose of a Request and Response objects, enabling strict typing. 

```crystal
module ExampleApp
  class IndexEndpoint 
    # Type Safe Endpoints
    include Endpoint(IndexRequest, IndexResponse)

    # Define the route for the endpoint
    get "/hello/:name"

    def call
      # Built in Error Types
      return BadRequest.new(errors: req.errors.messages) unless index_request.valid?

      status 200
      content_type "text/html"
      header "Custom", "Fake custom header"

      # ...call to domain layer...
      
      IndexPage.new index_request.name
    end
  end
end
```

### Request

Azu requests are contracts that you can validate 

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

Azu responses are define by including the `Response` module. 

```crystal
module ExampleApp
  class IndexPclassage
    include Markup
    include Response
    include Templates::Renderable
    
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