require "../src/azu"
require "schema"

module TestApp
  include Azu

  class HelloView
    include Azu::Html

    def initialize(@name : String)
    end

    def html
      "<h1>Hello #{@name}!</h1>"
    end
  end

  struct JsonData
    include Azu::Json

    def json
      { data: "Hello World" }.to_json
    end
  end

  struct HtmlPage
    include Azu::Html

    def initialize(@name : String)
    end

    def html
      doctype
      body do
        a(href: "http://crystal-lang.org") do
          text "#{@name} is awesome"
        end
      end
    end
  end

  class JsonEndpoint < Azu::Endpoint
    def call
      status 200
      JsonData.new
    end
  end

  class HtmlEndpoint < Azu::Endpoint
    def call
      status 200
      HtmlPage.new params.path["name"]
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
    get "/hello/:name", TestApp::HtmlEndpoint
    get "/hello/json", TestApp::JsonEndpoint
  end

  routes :loadtest do
    get "/helloworld", TestApp::LoadTest
  end
end

TestApp.start
