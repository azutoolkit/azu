require "../../src/azu"
require "schema"

module ExampleApp
  include Azu
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

ExampleApp::Pipeline[:web] = [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new
] of HTTP::Handler

ExampleApp.configure do
  templates.path = "spec/example_app/templates"
end

ExampleApp.router do
  root :web, ExampleApp::HelloWorld
  ws "/hi", ExampleApp::ExampleChannel

  routes :web, "/test" do
    post "/json/:id", ExampleApp::JsonEndpoint
    get "/hello/", ExampleApp::HelloWorld
    get "/hello/:name", ExampleApp::HtmlEndpoint
    get "/load/:name", ExampleApp::LoadTestEndpoint
  end
end

ExampleApp.start
