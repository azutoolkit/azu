require "../spec_helper"

describe Azu::Pipeline do
  pipeline = Azu::Pipeline.new
  renderer = HTTP::ErrorHandler.new
  scope = :test_scope

  pipeline.build scope do
    plug renderer
  end

  it "can build a pipeline" do
    pipeline.pipelines[scope].should eq [renderer]
  end
end
