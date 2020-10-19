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
  ExampleApp::Handler::Logger.new,
]

ExampleApp.configure do
  templates.path = "spec/example_app/templates"
end

ExampleApp.router do
  root :web, ExampleApp::HelloWorld
  ws "/hi", ExampleApp::ExampleChannel

  routes :web, "/test" do
    post "/json", ExampleApp::JsonEndpoint
    get "/hello/", ExampleApp::HelloWorld
    get "/hello/:name", ExampleApp::HtmlEndpoint
  end
end

ExampleApp.start
