require "../spec_helper"
require "yaml"

describe "Azu::VERSION" do
  it "is the version declared in shard.yml" do
    Azu::VERSION.should eq YAML.parse(File.read(File.join(__DIR__, "../../shard.yml")))["version"].as_s
  end

  it "reads plain, quoted and colon-bearing versions" do
    Azu.shard_version("name: azu\nversion: 0.5.73\n").should eq "0.5.73"
    Azu.shard_version(%(version: "1.2.3"\n)).should eq "1.2.3"
    Azu.shard_version("version: '1.2.3-rc:1'\n").should eq "1.2.3-rc:1"
  end
end
