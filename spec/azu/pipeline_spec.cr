require "../spec_helper"

describe Azu::Pipeline do
  pipeline = Azu::Pipeline.new
  handler = HTTP::ErrorHandler.new
  scope = :test_scope

  Azu::Pipeline[scope] = [handler]

  it "can build a pipeline" do
    Azu::Pipeline[scope].should eq Set{handler}
  end
end
