
# AZU
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/b58f03f01de241e0b75f222e31d905d7)](https://www.codacy.com/manual/eliasjpr/azu?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=eliasjpr/azu&amp;utm_campaign=Badge_Grade)

AZU is the artisans web application framework with expressive, elegant syntax that offers great performance to build rich, interactive type safe, web applications quickly, with less code and conhesive parts that adapts to your prefer style.

Join a growing community of developers using AZU to craft clean efficient APIs, HTML5 apps and more, for fun or at scale.

## Architecture

At its core, AZU is lightweight, fast and expresive without locking you to a a specific patter but instead offering the building blocks for your needs. Focus on your business domain, bring immediate productivity and long-term code maintainability. 

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

```crystal
require "azu"

module TestApp
  include Azu

  class HelloView < Azu::View
    def initialize(@name : String)
    end

    def html
      "<h1>Hello #{@name}!</h1>"
    end

    def text
      "Hello #{@name}!"
    end

    def json
      {hello: @name}.to_json
    end
  end

  class HelloWorld < Azu::Endpoint
    schema HelloRequest do
      param name : String, message: "Param name must be string.", presence: true
    end

    def call
      req = HelloRequest.new(params.query)
      Azu::BadRequest.new(errors: req.errors.messages) unless req.valid?
      header "Custom", "Fake custom header"
      status 300
      HelloView.new(params.query["name"].as(String))
    rescue ex
      raise Azu::BadRequest.from_exception(ex)
    end
  end
end

TestApp.configure do
end

TestApp.pipelines do
  build :web do
    plug Azu::Rescuer.new
    plug Azu::LogHandler.new TestApp.log
  end
end

TestApp.router do
  root :web, TestApp::HelloWorld
  routes :web, "/test" do
    get "/hello", TestApp::HelloWorld
  end
end

TestApp.start
```

## Contributing

    1. Fork it (<https://github.com/eliasjpr/azu/fork>)
    2. Create your feature branch (`git checkout -b my-new-feature`)
    3. Commit your changes (`git commit -am 'Add some feature'`)
    4. Push to the branch (`git push origin my-new-feature`)
    5. Create a new Pull Request

## Contributors

-   [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
