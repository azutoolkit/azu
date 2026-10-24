require "../../spec_helper"
require "../../support/spark_helpers"

module SparkConnectionSpec
  class Counter < Azu::Spark::Component
    mountable

    prop start : Int32 = 0
    state count : Int32 = 0, persist: true
    state heard : Array(String) = [] of String

    def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
      socket.reject!("nope") if socket.connected? && socket.session["role"]? == "banned"
      socket.subscribe("counter")
      self.count = start + params.fetch("plus", Int32, 0)
    end

    def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
      self.heard = heard + [message.payload]
    end

    event def increment : Nil
      self.count += 1
    end

    event def explode : Nil
      raise "secret internal detail"
    end

    def render
      div do
        span "count=#{count}"
        span "heard=#{heard.join(",")}"
        span "user=#{socket.session["user"]?}"
      end
    end
  end
end

module SparkConnectionSpec
  # Nothing it holds is persisted: a reconnect mounts it afresh.
  class Plain < Azu::Spark::Component
    mountable

    state clicks : Int32 = 0

    event def click : Nil
      self.clicks += 1
    end

    def render
      span "clicks=#{clicks}"
    end
  end
end

private def page(**props) : String
  Azu::Spark.render(SparkConnectionSpec::Counter, **props, session: {"user" => "ada"})
end

private def with_spark(&)
  previous = {Azu::Spark.config.max_message_size, Azu::Spark.config.events_per_second, Azu::Spark.config.event_burst, Azu::Spark.config.idle_timeout}
  with_ws_server(Azu::Channel::Upgrader.new(Azu::Spark::Connection)) do |port|
    yield port
  end
ensure
  if previous
    Azu::Spark.config.max_message_size, Azu::Spark.config.events_per_second, Azu::Spark.config.event_burst, Azu::Spark.config.idle_timeout = previous
  end
  Azu::PubSub.shutdown
end

private def with_spark_secret(secret : String, &)
  previous = Azu::Spark.config.secret
  Azu::Spark.config.secret = secret
  yield
ensure
  Azu::Spark.config.secret = previous
end

describe Azu::Spark::Connection do
  describe "joining and events" do
    it "greets, mounts the view from its token and applies events" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page(start: 10))

        hello = client.frame.not_nil!
        hello["type"].as_s.should eq "hello"
        hello["v"].as_i.should eq 1
        hello["heartbeat"].as_i.should be > 0

        id = client.join
        diff = client.await("diff")
        diff["patches"][0]["id"].as_s.should eq client.root_id
        diff["patches"][0]["html"].as_s.should contain "count=10"
        diff["patches"][0]["html"].as_s.should contain "user=ada"
        diff["seq"].as_i.should eq 1
        client.await("reply")["id"].as_i64.should eq id

        id = client.event("increment")
        diff = client.await("diff")
        diff["patches"][0]["html"].as_s.should contain "count=11"
        diff["seq"].as_i.should eq 2
        client.await("reply")["id"].as_i64.should eq id
        client.close
      end
    end

    it "hands the page parameters to mount" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join(params: {"plus" => "5"})

        client.await("diff")["patches"][0]["html"].as_s.should contain "count=5"
        client.close
      end
    end

    it "refuses a snapshot that was issued for another page" do
      with_spark do |port|
        first = SparkSpecClient.new(port, page)
        first.join
        first.await("diff")
        first.event("increment")
        snapshot = first.await("diff")["snapshots"][first.root_id].as_s
        first.close

        other = SparkSpecClient.new(port, page)
        other.join(snapshot: snapshot)

        other.await("error")["code"].as_s.should eq "invalid_snapshot"
        other.close
      end
    end

    it "restores persisted state when the same page reconnects with its snapshot" do
      with_spark do |port|
        same_page = page
        first = SparkSpecClient.new(port, same_page)
        first.join
        first.await("diff")
        3.times { first.event("increment") }
        snapshot = 3.times.map { first.await("diff")["snapshots"][first.root_id].as_s }.to_a.last
        first.close

        second = SparkSpecClient.new(port, same_page)
        second.join(snapshot: snapshot)

        second.await("diff")["patches"][0]["html"].as_s.should contain "count=3"
        second.close
      end
    end

    it "delivers PubSub broadcasts as diffs" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        Azu::PubSub.broadcast("counter", "ping")

        client.await("diff")["patches"][0]["html"].as_s.should contain "heard=ping"
        client.close
      end
    end

    it "answers heartbeats" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        id = client.send_frame("heartbeat")

        client.await("heartbeat")["id"].as_i64.should eq id
        client.close
      end
    end
  end

  describe "event delivery" do
    it "applies an event id once and answers a repeat with a duplicate reply and no diff" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        first = client.event("increment", eid: 1_i64)
        client.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        reply = client.await("reply")
        reply["id"].as_i64.should eq first
        reply["dup"]?.should be_nil

        again = client.event("increment", eid: 1_i64)
        duplicate = client.await("reply")
        duplicate["id"].as_i64.should eq again
        duplicate["dup"].as_bool.should be_true
        duplicate["ack"].as_i.should eq 1

        client.event("increment", eid: 2_i64)
        client.await("diff")["patches"][0]["html"].as_s.should contain "count=2"
        client.close
      end
    end

    it "ignores an id older than one already applied" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")
        client.event("increment", eid: 5_i64)
        client.await("diff")
        client.await("reply")

        client.event("increment", eid: 3_i64)
        client.await("reply")["dup"].as_bool.should be_true

        client.event("increment", eid: 6_i64)
        client.await("diff")["patches"][0]["html"].as_s.should contain "count=2"
        client.close
      end
    end

    it "piggybacks the id of the event on the diff, the reply and the error that answer it" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        client.event("increment", eid: 4_i64)
        client.await("diff")["ack"].as_i.should eq 4
        client.await("reply")["ack"].as_i.should eq 4

        client.event("destroy_everything", eid: 5_i64)
        client.await("error")["ack"].as_i.should eq 5
        client.close
      end
    end

    it "keeps serving clients that send no ids: nothing is deduplicated and no ack is added" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        2.times do
          client.event("increment")
          diff = client.await("diff")
          diff.as_h.has_key?("ack").should be_false
          client.await("reply").as_h.has_key?("ack").should be_false
        end
        client.event("increment")
        client.await("diff")["patches"][0]["html"].as_s.should contain "count=3"
        client.close
      end
    end

    it "rejects an event id that is not positive" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        client.event("increment", eid: 0_i64)
        client.await("error")["code"].as_s.should eq "bad_request"
        client.close
      end
    end

    it "names the generation of a root with persisted state in the reply to its join" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join

        client.await("reply")["gen"].as_s.should_not be_empty
        client.close
      end
    end

    it "names no generation for a root that persists nothing, and then never calls an event stale" do
      with_spark do |port|
        client = SparkSpecClient.new(port, Azu::Spark.render(SparkConnectionSpec::Plain))
        client.join
        client.await("reply").as_h.has_key?("gen").should be_false

        client.event("click", gen: "anything", eid: 1_i64)
        client.await("diff")["patches"][0]["html"].as_s.should contain "clicks=1"
        client.close
      end
    end

    it "applies an event of the generation it restored from a snapshot and refuses one of another, with a typed error" do
      with_spark do |port|
        same_page = page
        first = SparkSpecClient.new(port, same_page)
        first.join
        generation = first.await("reply")["gen"].as_s
        first.event("increment", eid: 1_i64, gen: generation)
        snapshot = first.await("diff")["snapshots"][first.root_id].as_s
        first.close

        restored = SparkSpecClient.new(port, same_page)
        restored.join(snapshot: snapshot)
        restored.await("reply")["gen"].as_s.should eq generation
        restored.event("increment", eid: 2_i64, gen: generation)
        restored.await("diff")["patches"][0]["html"].as_s.should contain "count=2"

        fresh = SparkSpecClient.new(port, same_page)
        fresh.join
        fresh.await("reply")["gen"].as_s.should_not eq generation
        id = fresh.event("increment", eid: 3_i64, gen: generation)
        error = fresh.await("error")
        error["code"].as_s.should eq "stale_event"
        error["id"].as_i64.should eq id
        error["ack"].as_i.should eq 3

        fresh.event("increment", eid: 4_i64)
        fresh.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        restored.close
        fresh.close
      end
    end

    it "starts without delivery state on a new connection: a resent id is applied there" do
      with_spark do |port|
        same_page = page
        first = SparkSpecClient.new(port, same_page)
        first.join
        first.await("reply")
        first.event("increment", eid: 1_i64)
        first.await("diff")
        first.close

        second = SparkSpecClient.new(port, same_page)
        second.join
        second.await("reply")
        second.event("increment", eid: 1_i64)
        second.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        second.close
      end
    end

    it "still closes connections that send oversized numbered events" do
      with_spark do |port|
        Azu::Spark.config.max_message_size = 128
        client = SparkSpecClient.new(port, page)
        client.frame # hello

        client.event("increment", eid: 1_i64, note: "x" * 2000)

        client.frame.should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::MessageTooBig
      end
    end
  end

  describe "errors" do
    it "reports malformed frames, bad tokens and unknown events with codes only the protocol defines" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.frame # hello

        client.probe.send("not json")
        client.await("error")["code"].as_s.should eq "bad_request"

        client.probe.send(%({"v":2,"type":"heartbeat"}))
        client.await("error")["code"].as_s.should eq "bad_request"

        client.send_frame("join", token: "forged.token")
        client.await("error")["code"].as_s.should eq "invalid_token"

        client.send_frame("bogus")
        client.await("error")["code"].as_s.should eq "bad_request"

        client.join
        client.await("reply")
        id = client.event("destroy_everything")
        error = client.await("error")
        error["code"].as_s.should eq "unknown_event"
        error["id"].as_i64.should eq id

        client.event("increment", target: "no-such-component")
        client.await("error")["code"].as_s.should eq "unknown_target"

        client.event("increment")
        client.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        client.close
      end
    end

    it "refuses to join twice with the same view and rejects views whose mount refuses" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")
        client.join
        client.await("error")["code"].as_s.should eq "bad_request"

        banned = SparkSpecClient.new(port, Azu::Spark.render(SparkConnectionSpec::Counter, session: {"role" => "banned"}))
        banned.join
        banned.await("error")["code"].as_s.should eq "rejected"
        client.close
        banned.close
      end
    end

    it "shows internal error details in development and hides them elsewhere" do
      with_spark do |port|
        {Azu::Environment::Development => true, Azu::Environment::Production => false}.each do |env, visible|
          with_spark_env(env) do
            with_spark_secret("an explicit secret for the spec") do
              client = SparkSpecClient.new(port, page)
              client.join
              client.await("reply")

              client.event("explode")
              error = client.await("error")

              error["code"].as_s.should eq "internal"
              error["message"].as_s.includes?("secret internal detail").should eq visible
              error.to_json.should_not contain "backtrace"
              client.close
            end
          end
        end
      end
    end
  end

  describe "isolation between clients" do
    it "does not let a client address components of another connection" do
      with_spark do |port|
        alice = SparkSpecClient.new(port, page)
        bob = SparkSpecClient.new(port, page)
        [alice, bob].each do |client|
          client.join
          client.await("reply")
        end

        alice.event("increment", target: bob.root_id)
        alice.await("error")["code"].as_s.should eq "unknown_target"

        bob.event("increment")
        bob.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        alice.close
        bob.close
      end
    end

    it "keeps serving client B when client A disconnects" do
      with_spark do |port|
        baseline = Azu::Spark.connection_count
        alice = SparkSpecClient.new(port, page)
        bob = SparkSpecClient.new(port, page)
        [alice, bob].each do |client|
          client.join
          client.await("reply")
        end
        wait_until { Azu::Spark.connection_count == baseline + 2 }.should be_true

        alice.close
        wait_until { Azu::Spark.connection_count == baseline + 1 }.should be_true

        bob.event("increment")
        bob.await("diff")["patches"][0]["html"].as_s.should contain "count=1"
        Azu::PubSub.broadcast("counter", "still here")
        bob.await("diff")["patches"][0]["html"].as_s.should contain "still here"
        bob.close
      end
    end

    it "releases every component, subscription and fiber of a closed connection" do
      with_spark do |port|
        backend = Azu::PubSub.backend.as(Azu::PubSub::Memory)
        baseline = backend.subscriber_count
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")
        backend.subscriber_count.should eq baseline + 1

        client.close

        wait_until { backend.subscriber_count == baseline }.should be_true
      end
    end
  end

  describe "limits" do
    it "names the numbered event a rate_limited error refuses, so the client can end it" do
      with_spark do |port|
        Azu::Spark.config.events_per_second = 1.0
        Azu::Spark.config.event_burst = 2
        client = SparkSpecClient.new(port, page)
        client.frame # hello
        6.times { |i| client.probe.send(%({"v":1,"type":"event","target":"x","event":"increment","payload":{},"id":#{i + 10},"eid":#{i + 1}})) }

        refused = [] of JSON::Any
        while frame = client.frame(500.milliseconds)
          refused << frame if frame["type"].as_s == "error" && frame["code"].as_s == "rate_limited"
        end

        refused.should_not be_empty
        refused.each { |answer| answer["ack"].as_i.should eq(answer["id"].as_i - 9) }
      end
    end

    it "reads the numbers of a refused event from frames with non-ASCII text and of flood size" do
      with_spark do |port|
        Azu::Spark.config.events_per_second = 1.0
        Azu::Spark.config.event_burst = 1
        client = SparkSpecClient.new(port, page)
        client.frame # hello
        text = "é日本" * 8000
        4.times { |i| client.probe.send(%({"v":1,"type":"event","target":"x","event":"increment","payload":{"t":"#{text}"},"id":#{i + 10},"eid":#{i + 1}})) }

        refused = [] of JSON::Any
        while frame = client.frame(500.milliseconds)
          refused << frame if frame["type"].as_s == "error" && frame["code"].as_s == "rate_limited"
        end

        refused.should_not be_empty
        refused.each { |answer| answer["ack"].as_i.should eq(answer["id"].as_i - 9) }
      end
    end

    it "answers floods with rate_limited errors and finally disconnects the client" do
      with_spark do |port|
        Azu::Spark.config.events_per_second = 1.0
        Azu::Spark.config.event_burst = 3
        client = SparkSpecClient.new(port, page)
        client.frame # hello
        20.times { client.send_frame("heartbeat") }

        codes = [] of String
        while frame = client.frame(500.milliseconds)
          codes << frame["code"].as_s if frame["type"].as_s == "error"
        end

        codes.should_not be_empty
        codes.uniq.should eq ["rate_limited"]
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::PolicyViolation
      end
    end

    it "closes connections that send oversized frames" do
      with_spark do |port|
        Azu::Spark.config.max_message_size = 128
        client = SparkSpecClient.new(port, page)
        client.frame # hello

        client.probe.send("x" * 2000)

        client.frame.should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::MessageTooBig
      end
    end

    it "disconnects idle clients" do
      with_spark do |port|
        Azu::Spark.config.idle_timeout = 100.milliseconds
        client = SparkSpecClient.new(port, page)
        client.frame # hello

        client.frame(2.seconds).should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::GoingAway
      end
    end

    it "caps the components a connection may own" do
      with_spark do |port|
        previous = Azu::Spark.config.max_components
        view = page
        Azu::Spark.config.max_components = 0
        begin
          client = SparkSpecClient.new(port, view)
          client.join
          client.await("error")["code"].as_s.should eq "limit_exceeded"
          client.close
        ensure
          Azu::Spark.config.max_components = previous
        end
      end
    end
  end

  describe "origin check" do
    it "refuses cross-site WebSocket upgrades" do
      with_spark do |port|
        expect_raises(Socket::Error, /403/) do
          SparkSpecClient.new(port, page, origin: "https://evil.example")
        end
      end
    end
  end

  describe "shutdown" do
    it "closes every connection with a service restart code" do
      with_spark do |port|
        client = SparkSpecClient.new(port, page)
        client.join
        client.await("reply")

        Azu::Spark.shutdown

        client.frame.should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::ServiceRestart
      end
    end
  end
end
