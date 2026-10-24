require "../../spec_helper"
require "../../support/spark_helpers"

module SparkCompressionSpec
  # Renders a long, repetitive list: its patch is large and compresses well.
  class Table < Azu::Spark::Component
    mountable

    prop rows : Int32 = 120
    state count : Int32 = 0

    event def increment : Nil
      self.count += 1
    end

    event def slow : Nil
      sleep 150.milliseconds
      self.count += 1
    end

    event def explode : Nil
      raise "secret internal detail"
    end

    def render
      div do
        span "count=#{count}"
        ul do
          rows.times { |row| li "row #{row}: the same words in every row", class: "row" }
        end
      end
    end
  end
end

private def table(rows : Int32 = 120) : String
  Azu::Spark.render(SparkCompressionSpec::Table, rows: rows)
end

private def with_threshold(threshold : Int32, &)
  previous = Azu::Spark.config.compress_threshold
  Azu::Spark.config.compress_threshold = threshold
  with_ws_server(Azu::Channel::Upgrader.new(Azu::Spark::Connection)) { |port| yield port }
ensure
  Azu::Spark.config.compress_threshold = previous if previous
  Azu::PubSub.shutdown
end

# Everything the server sends for one join and a few increments, as raw frames in arrival order.
private def conversation(client : SparkSpecClient, enc : Array(String)?, events : Int32 = 3) : Array(JSON::Any)
  client.frame # hello
  client.join(enc: enc)
  frames = [] of JSON::Any
  2.times { frames << client.frame.not_nil! } # diff, reply
  events.times do
    client.event("increment")
    2.times { frames << client.frame.not_nil! }
  end
  frames
end

describe "compressed Spark frames" do
  it "configures the threshold, 1 KB by default" do
    Azu::Spark::Configuration.new.compress_threshold.should eq 1024
  end

  it "sends a large diff as one binary gzip frame to a client that announced gzip" do
    with_threshold(1024) do |port|
      client = SparkSpecClient.new(port, table)
      frames = conversation(client, ["gzip"])

      client.binary_sizes.size.should eq 4 # the diff of the join and of each event; the replies stay text
      frames.map(&.["type"].as_s).should eq %w(diff reply diff reply diff reply diff reply)
      frames.select { |frame| frame["type"] == "diff" }.map(&.["seq"].as_i).should eq [1, 2, 3, 4]
      frames[0]["patches"][0]["html"].as_s.should contain "count=0"
      frames[6]["patches"][0]["html"].as_s.should contain "count=3"
      client.close
    end
  end

  it "answers the join with the encoding it will use" do
    with_threshold(1024) do |port|
      client = SparkSpecClient.new(port, table)
      frames = conversation(client, ["gzip"], events: 0)
      frames[1]["enc"].as_s.should eq "gzip"
      client.close
    end
  end

  it "inflates to exactly the frame an old client receives as text" do
    with_threshold(1024) do |port|
      page = table
      old = SparkSpecClient.new(port, page)
      new = SparkSpecClient.new(port, page)
      plain = conversation(old, nil)
      packed = conversation(new, ["gzip"])

      packed.select { |frame| frame["type"] == "diff" }.map(&.to_json).should eq plain.select { |frame| frame["type"] == "diff" }.map(&.to_json)
      old.binary_sizes.should be_empty
      new.binary_sizes.sum.should be < plain.sum(&.to_json.bytesize) // 4
      old.close
      new.close
    end
  end

  it "keeps the frames of a client that announces nothing exactly as protocol v1 had them" do
    with_threshold(1024) do |port|
      client = SparkSpecClient.new(port, table)
      client.frame.not_nil!.to_json.should eq %({"v":1,"type":"hello","heartbeat":20000,"max_size":65536})
      client.join
      big = client.probe.receive.not_nil! # a text frame: the probe raises on a binary one
      big.bytesize.should be > 1024
      JSON.parse(big)["type"].as_s.should eq "diff"
      client.probe.receive.not_nil!.should match(/\A\{"v":1,"type":"reply","id":1(,"gen":"[^"]+")?\}\z/)
      client.close
    end
  end

  it "sends small diffs as text even to a client that announced gzip" do
    with_threshold(1024) do |port|
      client = SparkSpecClient.new(port, table(rows: 1))
      conversation(client, ["gzip"])
      client.binary_sizes.should be_empty
      client.close
    end
  end

  it "ignores an encoding it does not know" do
    with_threshold(1024) do |port|
      client = SparkSpecClient.new(port, table)
      frames = conversation(client, ["br", "zstd"], events: 1)
      client.binary_sizes.should be_empty
      frames[1].as_h.has_key?("enc").should be_false
      client.close
    end
  end

  it "honours the configured threshold, and 0 turns compression off" do
    with_threshold(1_000_000) do |port|
      client = SparkSpecClient.new(port, table)
      conversation(client, ["gzip"], events: 1)
      client.binary_sizes.should be_empty
      client.close
    end

    with_threshold(0) do |port|
      client = SparkSpecClient.new(port, table)
      conversation(client, ["gzip"], events: 1)
      client.binary_sizes.should be_empty
      client.close
    end
  end

  describe "the backlog guard" do
    backlog = -> { Azu::Spark.connections.last.backlog }

    it "keeps a diff as text while more work waits behind its job, and compresses the next one" do
      with_threshold(1024) do |port|
        client = SparkSpecClient.new(port, table)
        client.frame
        client.join(enc: ["gzip"])
        2.times { client.frame } # the join's diff and reply
        client.event("slow")
        client.event("increment") # arrives while "slow" sleeps: queued behind it
        4.times { client.frame }
        client.kinds.last(4).should eq [:text, :text, :binary, :text] # diff of slow (text), its reply, diff of increment, reply
        client.close
      end
    end

    it "returns to zero after the work completes" do
      with_threshold(1024) do |port|
        client = SparkSpecClient.new(port, table)
        client.frame
        client.join
        2.times { client.frame }
        client.event("slow")
        client.event("increment")
        4.times { client.frame }
        backlog.call.should eq 0
        client.close
      end
    end

    it "returns to zero after a handler raised" do
      with_threshold(1024) do |port|
        client = SparkSpecClient.new(port, table)
        client.frame
        client.join
        2.times { client.frame }
        client.event("explode")
        client.await("error")["code"].as_s.should eq "internal"
        backlog.call.should eq 0
        client.close
      end
    end

    it "returns to zero when the inbox was closed under the enqueue" do
      socket = HTTP::WebSocket.new(IO::Memory.new)
      connection = Azu::Spark::Connection.new(socket)
      connection.on_close(nil, nil)
      connection.on_message(%({"v":1,"type":"heartbeat","id":1}))

      connection.backlog.should eq 0
    end
  end
end
