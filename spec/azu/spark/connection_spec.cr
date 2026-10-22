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

  # Opens a socket against a server running the Spark connection and plays the client side.
  class Client
    getter probe : WsProbe
    getter root_id : String
    getter token : String
    @next_id = 0_i64

    def initialize(port : Int32, page : String, origin : String? = nil)
      @root_id = page.match!(/data-spark-id='([^']+)'/)[1]
      @token = page.match!(/data-spark-token='([^']+)'/)[1]
      @probe = WsProbe.new(port, "/spark", origin: origin || "http://127.0.0.1:#{port}")
    end

    def frame(timeout : Time::Span = 2.seconds) : JSON::Any?
      @probe.receive(timeout).try { |text| JSON.parse(text) }
    end

    def send_frame(type : String, **fields) : Int64
      id = (@next_id += 1)
      @probe.send({v: 1, type: type, id: id}.merge(fields).to_json)
      id
    end

    def join(snapshot : String? = nil, params : Hash(String, String) = {} of String => String) : Int64
      send_frame("join", token: @token, snapshot: snapshot, params: params)
    end

    def event(name : String, target : String = @root_id, **payload) : Int64
      send_frame("event", target: target, event: name, payload: payload)
    end

    # Reads frames until one of *type* arrives.
    def await(type : String) : JSON::Any
      5.times do
        frame = self.frame || break
        return frame if frame["type"].as_s == type
      end
      raise "no #{type} frame arrived"
    end

    def close : Nil
      @probe.close
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

private def wait_until(timeout : Time::Span = 2.seconds, &) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant > deadline
    sleep 5.milliseconds
  end
  true
end

describe Azu::Spark::Connection do
  describe "joining and events" do
    it "greets, mounts the view from its token and applies events" do
      with_spark do |port|
        client = SparkConnectionSpec::Client.new(port, page(start: 10))

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
        client = SparkConnectionSpec::Client.new(port, page)
        client.join(params: {"plus" => "5"})

        client.await("diff")["patches"][0]["html"].as_s.should contain "count=5"
        client.close
      end
    end

    it "ignores a snapshot that was issued for another page" do
      with_spark do |port|
        first = SparkConnectionSpec::Client.new(port, page)
        first.join
        first.await("diff")
        first.event("increment")
        snapshot = first.await("diff")["snapshots"][first.root_id].as_s
        first.close

        other = SparkConnectionSpec::Client.new(port, page)
        other.join(snapshot: snapshot)

        other.await("diff")["patches"][0]["html"].as_s.should contain "count=0"
        other.close
      end
    end

    it "restores persisted state when the same page reconnects with its snapshot" do
      with_spark do |port|
        same_page = page
        first = SparkConnectionSpec::Client.new(port, same_page)
        first.join
        first.await("diff")
        3.times { first.event("increment") }
        snapshot = 3.times.map { first.await("diff")["snapshots"][first.root_id].as_s }.to_a.last
        first.close

        second = SparkConnectionSpec::Client.new(port, same_page)
        second.join(snapshot: snapshot)

        second.await("diff")["patches"][0]["html"].as_s.should contain "count=3"
        second.close
      end
    end

    it "delivers PubSub broadcasts as diffs" do
      with_spark do |port|
        client = SparkConnectionSpec::Client.new(port, page)
        client.join
        client.await("reply")

        Azu::PubSub.broadcast("counter", "ping")

        client.await("diff")["patches"][0]["html"].as_s.should contain "heard=ping"
        client.close
      end
    end

    it "answers heartbeats" do
      with_spark do |port|
        client = SparkConnectionSpec::Client.new(port, page)
        id = client.send_frame("heartbeat")

        client.await("heartbeat")["id"].as_i64.should eq id
        client.close
      end
    end
  end

  describe "errors" do
    it "reports malformed frames, bad tokens and unknown events with codes only the protocol defines" do
      with_spark do |port|
        client = SparkConnectionSpec::Client.new(port, page)
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
        client = SparkConnectionSpec::Client.new(port, page)
        client.join
        client.await("reply")
        client.join
        client.await("error")["code"].as_s.should eq "bad_request"

        banned = SparkConnectionSpec::Client.new(port, Azu::Spark.render(SparkConnectionSpec::Counter, session: {"role" => "banned"}))
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
              client = SparkConnectionSpec::Client.new(port, page)
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
        alice = SparkConnectionSpec::Client.new(port, page)
        bob = SparkConnectionSpec::Client.new(port, page)
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
        alice = SparkConnectionSpec::Client.new(port, page)
        bob = SparkConnectionSpec::Client.new(port, page)
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
        client = SparkConnectionSpec::Client.new(port, page)
        client.join
        client.await("reply")
        backend.subscriber_count.should eq baseline + 1

        client.close

        wait_until { backend.subscriber_count == baseline }.should be_true
      end
    end
  end

  describe "limits" do
    it "answers floods with rate_limited errors and finally disconnects the client" do
      with_spark do |port|
        Azu::Spark.config.events_per_second = 1.0
        Azu::Spark.config.event_burst = 3
        client = SparkConnectionSpec::Client.new(port, page)
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
        client = SparkConnectionSpec::Client.new(port, page)
        client.frame # hello

        client.probe.send("x" * 2000)

        client.frame.should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::MessageTooBig
      end
    end

    it "disconnects idle clients" do
      with_spark do |port|
        Azu::Spark.config.idle_timeout = 100.milliseconds
        client = SparkConnectionSpec::Client.new(port, page)
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
          client = SparkConnectionSpec::Client.new(port, view)
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
          SparkConnectionSpec::Client.new(port, page, origin: "https://evil.example")
        end
      end
    end
  end

  describe "shutdown" do
    it "closes every connection with a service restart code" do
      with_spark do |port|
        client = SparkConnectionSpec::Client.new(port, page)
        client.join
        client.await("reply")

        Azu::Spark.shutdown

        client.frame.should be_nil
        client.probe.close_code.should eq HTTP::WebSocket::CloseCode::ServiceRestart
      end
    end
  end
end
