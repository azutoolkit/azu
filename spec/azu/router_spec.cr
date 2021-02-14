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
    router.add "/", ExampleEndpoint, Azu::Method::Get
  end
end
