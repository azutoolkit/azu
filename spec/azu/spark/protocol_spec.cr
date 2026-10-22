require "../../spec_helper"

describe Azu::Spark::Protocol do
  describe "inbound frames" do
    it "parses a join request" do
      frame = Azu::Spark::Protocol::Inbound.from_json(%({"v":1,"type":"join","id":3,"token":"t","snapshot":"s","params":{"q":"x"}}))

      frame.type.should eq "join"
      frame.id.should eq 3
      frame.token.should eq "t"
      frame.snapshot.should eq "s"
      frame.params.should eq({"q" => "x"})
    end

    it "parses an event with a heterogeneous payload and ignores unknown fields" do
      frame = Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":9,"target":"c","event":"add","payload":{"n":1,"tags":["a"]},"future":true}))

      frame.v.should eq 1
      frame.payload.not_nil!["n"].as_i.should eq 1
      frame.payload.not_nil!["tags"].as_a.size.should eq 1
    end

    it "rejects frames of the wrong shape" do
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"id":1})) }
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":"one"})) }
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","payload":[1]})) }
    end
  end

  describe "outbound frames" do
    it "encodes a diff with patches, browser events and snapshots" do
      update = Azu::Spark::Update.new(
        patches: [Azu::Spark::Update::Patch.new("root", "<b>1</b>")],
        pushes: [Azu::Spark::Update::Push.new("root", "saved", JSON.parse(%({"id":1})))],
        snapshots: {"root" => "tok"})

      frame = JSON.parse(Azu::Spark::Protocol.diff(7, update))

      frame["v"].as_i.should eq 1
      frame["type"].as_s.should eq "diff"
      frame["seq"].as_i.should eq 7
      frame["patches"][0]["html"].as_s.should eq "<b>1</b>"
      frame["events"][0]["name"].as_s.should eq "saved"
      frame["events"][0]["payload"]["id"].as_i.should eq 1
      frame["snapshots"]["root"].as_s.should eq "tok"
    end

    it "encodes replies, errors, heartbeats, redirects and hello" do
      JSON.parse(Azu::Spark::Protocol.reply(4, "root")).as_h.should eq({"v" => 1, "type" => "reply", "id" => 4, "target" => "root"})
      JSON.parse(Azu::Spark::Protocol.error(nil, "bad_request", "no")).as_h.should eq({"v" => 1, "type" => "error", "id" => nil, "code" => "bad_request", "message" => "no"})
      JSON.parse(Azu::Spark::Protocol.heartbeat(2)).as_h["type"].as_s.should eq "heartbeat"
      JSON.parse(Azu::Spark::Protocol.redirect(Azu::Spark::Update::Redirect.new("/a", true))).as_h["replace"].as_bool.should be_true
      JSON.parse(Azu::Spark::Protocol.hello(20.seconds, 65536)).as_h["heartbeat"].as_i.should eq 20_000
    end
  end
end
