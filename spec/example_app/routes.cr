require "../../src/azu"

module ExampleApp
  include Azu
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

require "schema"

ExampleApp.configure do
end

ExampleApp.pipelines do
  build :web do
    plug Azu::Rescuer.new
    plug Azu::Logger.new
  end

  build :loadtest do
  end
end

ExampleApp.router do
  root :web, ExampleApp::HelloWorld
  ws "/hi", ExampleApp::ExampleChannel

  routes :web, "/test" do
    get "/hello", ExampleApp::HelloWorld
    get "/hello/:name", ExampleApp::HtmlEndpoint
    get "/hello/json", ExampleApp::JsonEndpoint
  end
end

ExampleApp.start
