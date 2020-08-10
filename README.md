# AZU
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/b58f03f01de241e0b75f222e31d905d7)](https://www.codacy.com/manual/eliasjpr/azu?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=eliasjpr/azu&amp;utm_campaign=Badge_Grade)

AZU is the artisans web application framework with expressive, elegant syntax that offers great performance to build rich, interactive type safe, web applications quickly, with less code and conhesive parts that adapts to your prefer style.

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
ExampleApp.pipelines do
  build :web do
    plug Azu::Rescuer.new
    plug Azu::LogHandler.new TestApp.log
  end
end

# Defines routes
ExampleApp.router do
  root :web, ExampleApp::IndexEndpoint

  routes :web, "/test" do
    get "/hello", ExampleApp::IndexEndpoint
  end
end

# Starts the http server
ExampleApp.start
```

### Azu::Endpoint Example

```crystal
module ExampleApp
  class IndexEndpoint 
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
  end
end
```

### Azu::Response Objects

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

### Azu::Request Objects

```crystal
module ExampleApp
  class IndexRequest
    # Defines this class as an Azu::Request 
    include Azu::Request

    # To use type safe params
    include Azu::Contract

    # Defines your request object expected properties (query, form, path) macro available
    query name : String, message: "Param name must be string.", presence: true

    # Without type safe params
    def name
      params.query["name"]
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
