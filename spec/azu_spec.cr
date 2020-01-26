require "./spec_helper"

class ExampleEndpoint < Azu::Endpoint
end

describe Azu::Router do
  router = Azu::Router.new
  path = "/example_router"
  
  it "adds endpoint" do
    router.add :web, Azu::Method::Get, "/", ExampleEndpoint
  end

  it "defines rest resources" do
    router.resources :web, path, ExampleEndpoint
  end
end
 