require "../spec_helper"
require "yaml"

describe "Azu::VERSION" do
  it "is the version declared in shard.yml" do
    Azu::VERSION.should eq YAML.parse(File.read("shard.yml"))["version"].as_s
  end
end
