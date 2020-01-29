require "./azu"

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
  def call
    HelloView.new(params["name"].as(String))
  end
end

Azu.pipelines do
  build :web do
    plug Azu::LogHandler.new
  end
end

Azu.router do
  root HelloWorld
  routes :web, "/test" do
    get "/hello", HelloWorld
  end
end

Azu::Server.start
