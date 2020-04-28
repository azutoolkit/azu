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
    req = HelloRequest.new(params.query)
    Azu::BadRequest.new(errors: req.errors.messages) unless req.valid?
    header "Custom", "Fake custom header"
    status 300
    HelloView.new(params.query["name"].as(String))
  rescue ex
    raise Azu::BadRequest.from_exception(ex)
  end
end

Azu.pipelines do
  build :web do
    plug Azu::LogHandler.new
    plug Azu::Rescuer.new
  end
end

Azu.router do
  root :web, HelloWorld
  routes :web, "/test" do
    get "/hello", HelloWorld
  end
end

Azu::Server.start
