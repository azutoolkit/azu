require "../src/azu"
require "schema"

module TestApp
  include Azu

  class HelloView < Azu::View
    def initialize(@name : String)
    end

    def html
      "<h1>Hello #{@name}!</h1>"
    end

    def text
      "Hello World!"
    end

    def json
      {hello: "world"}.to_json
    end

    def xml
      "<hello>world!<hello>"
    end
  end

  class LoadTest < Azu::Endpoint
    def call
      "Hello World!"
    end
  end

  class HiChannel < Azu::Channel
    SUBSCRIBERS = [] of HTTP::WebSocket

    def on_connect
      SUBSCRIBERS << socket.not_nil!
      @socket.not_nil!.send SUBSCRIBERS.size.to_s
    end

    def on_binary(binary)
    end

    def on_pong(message)
    end

    def on_ping(message)
    end

    def on_message(message)
      SUBSCRIBERS.each { |s| s.send "Polo!" }
    end

    def on_close(code, message = nil)
      SUBSCRIBERS.delete socket
    end
  end

  class HelloWorld < Azu::Endpoint
    def call
      name = params.query["name"]
      raise Azu::BadRequest.new(errors: ["No name is present"]) if name.empty?
      header "Custom", "Fake custom header"
      HelloView.new name
    rescue ex
      raise Azu::BadRequest.from_exception ex
    end
  end
end

TestApp.configure do
end

TestApp.pipelines do
  build :web do
    plug Azu::Rescuer.new
    plug Azu::Logger.new
  end

  build :loadtest do
  end
end

TestApp.router do
  root :web, TestApp::HelloWorld

  ws "/hi", TestApp::HiChannel

  routes :web, "/test" do
    get "/hello", TestApp::HelloWorld
  end

  routes :loadtest do
    get "/helloworld", TestApp::LoadTest
  end
end

TestApp.start
