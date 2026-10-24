require "../../spec_helper"
require "compress/gzip"

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

    it "parses the optional frame encodings a client can decode, nil for a client that announces none" do
      Azu::Spark::Protocol::Inbound.from_json(%({"v":1,"type":"join","id":1,"token":"t","enc":["gzip"]})).enc.should eq ["gzip"]
      Azu::Spark::Protocol::Inbound.from_json(%({"v":1,"type":"join","id":1,"token":"t"})).enc.should be_nil
    end

    it "parses an event with a heterogeneous payload and ignores unknown fields" do
      frame = Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":9,"target":"c","event":"add","payload":{"n":1,"tags":["a"]},"future":true}))

      frame.v.should eq 1
      frame.payload.not_nil!["n"].as_i.should eq 1
      frame.payload.not_nil!["tags"].as_a.size.should eq 1
    end

    it "parses the optional delivery fields of an event and leaves them nil for older clients" do
      numbered = Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":9,"target":"c","event":"add","eid":12,"gen":"ab12"}))
      numbered.eid.should eq 12
      numbered.gen.should eq "ab12"

      plain = Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":9,"target":"c","event":"add"}))
      plain.eid.should be_nil
      plain.gen.should be_nil
    end

    it "rejects frames of the wrong shape" do
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"id":1})) }
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","id":"one"})) }
      expect_raises(JSON::SerializableError) { Azu::Spark::Protocol::Inbound.from_json(%({"type":"event","payload":[1]})) }
    end
  end

  describe "outbound frames" do
    it "adds ack, dup and gen only when given, so frames for older clients are unchanged" do
      reply = JSON.parse(Azu::Spark::Protocol.reply(4, "root", ack: 9_i64, dup: true)).as_h
      reply["ack"].as_i.should eq 9
      reply["dup"].as_bool.should be_true
      JSON.parse(Azu::Spark::Protocol.reply(4, nil, gen: "g1")).as_h["gen"].as_s.should eq "g1"
      JSON.parse(Azu::Spark::Protocol.reply(4)).as_h.has_key?("dup").should be_false
      JSON.parse(Azu::Spark::Protocol.error(4, "stale_event", "no", ack: 9_i64)).as_h["ack"].as_i.should eq 9
      JSON.parse(Azu::Spark::Protocol.diff(1, Azu::Spark::Update.new, ack: 9_i64)).as_h["ack"].as_i.should eq 9
      JSON.parse(Azu::Spark::Protocol.diff(1, Azu::Spark::Update.new)).as_h.has_key?("ack").should be_false
    end

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

  describe "compressed frames" do
    inflate = ->(bytes : Bytes) { Compress::Gzip::Reader.open(IO::Memory.new(bytes), &.gets_to_end) }
    markup = "<li class=\"row\">a fairly repetitive list item</li>" * 200

    it "gzips a frame at or above the threshold into bytes that inflate to exactly the same JSON" do
      frame = Azu::Spark::Protocol.diff(1, Azu::Spark::Update.new(patches: [Azu::Spark::Update::Patch.new("r", markup)]))
      bytes = Azu::Spark::Protocol.gzip(frame, 1024).not_nil!

      bytes.size.should be < frame.bytesize // 4
      inflate.call(bytes).should eq frame
      Azu::Spark::Protocol.gzip(frame, frame.bytesize).should_not be_nil
    end

    it "leaves a frame below the threshold as text" do
      frame = Azu::Spark::Protocol.diff(1, Azu::Spark::Update.new(patches: [Azu::Spark::Update::Patch.new("r", markup)]))

      Azu::Spark::Protocol.gzip(frame, frame.bytesize + 1).should be_nil
      Azu::Spark::Protocol.gzip("{}", 1).should be_nil # tiny frames never shrink
    end

    it "does not compress when it would not save bytes" do
      random = Random::Secure.hex(20) # 40 characters of entropy: the gzip header alone outweighs any gain

      Azu::Spark::Protocol.gzip(random, 1).should be_nil
    end

    it "never compresses a frame that would inflate past the limit the client enforces" do
      Azu::Spark::Protocol::MAX_INFLATED.should eq 1_048_576
      Azu::Spark::Protocol.gzip("x" * (Azu::Spark::Protocol::MAX_INFLATED + 1), 1024).should be_nil
      Azu::Spark::Protocol.gzip("x" * Azu::Spark::Protocol::MAX_INFLATED, 1024).should_not be_nil
    end

    it "sends as text a frame whose gzip would exceed what the client accepts on the wire" do
      Azu::Spark::Protocol::MAX_COMPRESSED.should eq 524_288
      noisy = String.new(Random::Secure.random_bytes(Azu::Spark::Protocol::MAX_INFLATED).map { |byte| (byte % 94 + 33).to_u8 })

      Azu::Spark::Protocol.gzip(noisy, 1024).should be_nil # about 80% of 1 MiB: smaller than the frame, yet too big to send
    end

    it "adds enc to the reply of a join only when it was negotiated" do
      JSON.parse(Azu::Spark::Protocol.reply(1, enc: "gzip")).as_h["enc"].as_s.should eq "gzip"
      JSON.parse(Azu::Spark::Protocol.reply(1)).as_h.has_key?("enc").should be_false
    end
  end
end
