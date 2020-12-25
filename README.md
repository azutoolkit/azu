# AZU
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/b58f03f01de241e0b75f222e31d905d7)](https://www.codacy.com/manual/eliasjpr/azu?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=eliasjpr/azu&amp;utm_campaign=Badge_Grade) ![Crystal CI](https://github.com/eliasjpr/azu/workflows/Crystal%20CI/badge.svg?branch=master)

AZU is the artisans web application framework with expressive, elegant syntax that offers great performance to build rich, interactive type safe, web applications quickly, with less code and conhesive parts that adapts to your prefer style. 

Azu Framework benefits:

* Plain Crystal, little DSL
* Supe easy to leanr and adopt
* Type safe everywhere
* Adopts your Organization architectural pattern: 
  * Modular
  * Pipes and Filters
  * Event Driven
  * Layered
  * etc
* Great Designing APIs
* API Design First Approach - Generate app from Swagger specs

Join a growing community of developers using AZU to craft clean efficient APIs, HTML5 apps and more, for fun or at scale.

## Architecture

At its core, AZU is lightweight, fast and expresive without locking you to a a specific pattern but instead offering the building blocks for your needs. Focus on your business domain, bring immediate productivity and long-term code maintainability. 

## Installation

  1.  Add the dependency to your `shard.yml`:

      ```yaml
      dependencies:
        azu:
          github: eliasjpr/azu
      ```

  2.  Run `shards install`

## Usage

### Environment Variables

```shell
export CRYSTAL_ENV=development
export CRYSTAL_LOG_SOURCES="*"
export CRYSTAL_LOG_LEVEL=DEBUG
export PORT=4000
export PORT_REUSE=false
export HOST=0.0.0.0
```

## Pipelines, Routes, Endpoints, Requests and Responses examples

```crystal
module ExampleApp
  include Azu
end

# Define different pipelines to process requests
ExampleApp::Pipeline[:web] = [
  ExampleApp::Handler::Logger.new,
]

# Configure template path 
ExampleApp.configure do
  templates.path = "spec/example_app/templates"
end

# Defines routes
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

# Starts the http server
ExampleApp.start
```

### Azu::Endpoint Example

Azu Endpoints are compose of a Request and Response objects, enabling strict typing for requests. If you want to have and Request or Response types simple define your endpoints with `include Azu::Endpoint(Azu::Request, Azu::Response)`.

TO access the Crystal http request object  

```crystal
module ExampleApp
  class IndexEndpoint 
    # Type Safe Endpoints
    include Azu::Endpoint(IndexRequest, IndexResponse)

    def call
      Azu::BadRequest.new(errors: req.errors.messages) unless request.valid?

      header "Custom", "Fake custom header"
      status 300

      ...call to domain layer...
      
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

### Azu::Request Objects

Azu requests are define by either defining a `struct` or `class` that includes the `Azu::Request` module. `Azu::Request` can be used as a generic request type. You can validate your requests with `valid?`, `validate!` and the `errors` method.

```crystal
module ExampleApp
  class IndexRequest
    # Defines this class as an Azu::Request 
    include Azu::Request

    # Defines your request object expected properties (query, form, path) macros are available
    query name : String, message: "Param name must be string.", presence: true

    # Without type safe params
    def name
      params.query["name"]
    end
  end
end
```

### Azu::Response Objects

Azu responses are define by including one of the response types `Html`, `Error`, `Json`, `Text`, `Xml`. The response
module tells the Azu how to treat the response. `Azu::Response` can be used as a generic response type

```crystal
module ExampleApp
  class IndexPage
    # Enables HTML Responses
    include Azu::Html
    
    def initialize(@name : String)
    end

    # Define HTML method for HTML Response
    def html
      # Uss built in html builder for folks who enjoy html as code vs templates
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

## Contributing

    1. Fork it (<https://github.com/eliasjpr/azu/fork>)
    2. Create your feature branch (`git checkout -b my-new-feature`)
    3. Commit your changes (`git commit -am 'Add some feature'`)
    4. Push to the branch (`git push origin my-new-feature`)
    5. Create a new Pull Request

## Contributors

-   [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
