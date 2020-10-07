require "../../src/azu"

module ExampleApp
  include Azu
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

require "schema"

ExampleApp::Pipeline[:web] = [
  ExampleApp::Handler::Rescuer.new,
  ExampleApp::Handler::Logger.new,
]

ExampleApp.configure do
  templates.path = "spec/example_app/templates"
end

ExampleApp.router do
  root :web, ExampleApp::HelloWorld
  ws "/hi", ExampleApp::ExampleChannel

  routes :web, "/test" do
    get "/hello/", ExampleApp::HelloWorld
    get "/hello/:name", ExampleApp::HtmlEndpoint
    get "/hello/json", ExampleApp::JsonEndpoint
  end
end

ExampleApp.start
