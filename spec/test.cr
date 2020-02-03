require "../src/azu"
require "schema"

Azu.configure do
end

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
    hello_request = HelloRequest.new(params.query)
    errors(hello_request.errors) unless hello_request.valid?
    header "Custom", "Fake custom header"
    status 300
    HelloView.new(params.query["name"].as(String))
  end

  private def errors(errors)
    err = errors.map { |e| e.message }
    raise Azu::MissingParam.new(errors: err)
  end
end

Azu.pipelines do
  build :web do
    plug Azu::LogHandler.new
  end
end

Azu.router do
  root :web, HelloWorld
  routes :web, "/test" do
    get "/hello", HelloWorld
  end
end

Azu::Server.start
