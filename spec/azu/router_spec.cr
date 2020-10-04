require "../spec_helper"

class ExampleEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  def call : Azu::Response
  end
end

describe Azu::Router do
  router = Azu::Router.new
  path = "/example_router"

  it "adds endpoint" do
    router.add "/", ExampleEndpoint, :web, Azu::Method::Get
  end

  it "defines rest resources" do
    router.routes :web do
      get path, ExampleEndpoint
    end
  end
end
