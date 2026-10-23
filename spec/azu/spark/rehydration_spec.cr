require "../../spec_helper"
require "../../support/spark_helpers"

module SparkRehydrationSpec
  class Tally < Azu::Spark::Component
    prop label : String
    state taps : Int32 = 0, persist: true

    class_property unmounted = 0

    def unmount(socket : Azu::Spark::Socket) : Nil
      Tally.unmounted += 1
    end

    event def tap : Nil
      self.taps = taps + 1
    end

    def render
      span "#{label}=#{taps}"
    end
  end

  class Board < Azu::Spark::Component
    mountable

    state notes : Array(String) = [] of String, persist: true
    state scratch : String = "fresh"

    event def add(text : String) : Nil
      self.notes = notes + [text]
      self.scratch = "touched"
    end

    def render
      div do
        span "notes=#{notes.join(",")}"
        span "scratch=#{scratch}"
        live Tally, key: "tally", label: "taps"
      end
    end
  end

  class Pair < Azu::Spark::Component
    mountable

    def render
      div do
        live Tally, key: "a", label: "a"
        live Tally, key: "b", label: "b"
      end
    end
  end

  SECRET = "rehydration-spec-secret-rehydration-spec"
  USER   = {"user" => "ada"}
end

private def board_page(session = SparkRehydrationSpec::USER) : String
  Azu::Spark.render(SparkRehydrationSpec::Board, session: session)
end

private def with_board_server(&)
  previous = {Azu::Spark.config.secret, Azu::Spark.config.max_snapshot_size}
  Azu::Spark.config.secret = SparkRehydrationSpec::SECRET
  # Development shows the reason of an error, which is what these specs look for.
  with_spark_env(Azu::Environment::Development) do
    with_ws_server(Azu::Channel::Upgrader.new(Azu::Spark::Connection)) { |port| yield port }
  end
ensure
  if previous
    Azu::Spark.config.secret, Azu::Spark.config.max_snapshot_size = previous
  end
  Azu::PubSub.shutdown
end

# Joins *page* and plays a session: returns the latest snapshot the server issued.
private def play(client : SparkSpecClient) : String
  client.join
  client.await("reply")
  client.event("add", text: "milk")
  client.await("reply")
  2.times do
    client.event("tap", target: "#{client.root_id}~tally")
    client.await("reply")
  end
  client.event("add", text: "eggs")
  snapshot = nil
  until snapshot
    frame = client.await("diff")
    snapshot = frame["snapshots"]?.try(&.[client.root_id]?).try(&.as_s?) if frame["patches"].as_a.any?(&.["html"].as_s.includes?("eggs"))
  end
  snapshot
end

private def sign_snapshot(root_id : String, members : Hash(String, Azu::Spark::Snapshot::Member),
                          session = SparkRehydrationSpec::USER, ttl = 1.hour, max_size = 4096) : String
  Azu::Spark::Snapshot.sign(root_id, session, members, ttl, SparkRehydrationSpec::SECRET, max_size) || raise "snapshot not signed"
end

private def member(type : String, **state) : Azu::Spark::Snapshot::Member
  Azu::Spark::Snapshot::Member.new(type, JSON.parse(state.to_json))
end

private def rejected(client : SparkSpecClient, snapshot : String) : JSON::Any
  client.join(snapshot: snapshot)
  error = client.await("error")
  error["code"].as_s.should eq "invalid_snapshot"
  error
end

describe "Spark rehydration" do
  it "re-mounts the components of a dropped connection from the signed snapshot and carries on" do
    with_board_server do |port|
      page = board_page
      first = SparkSpecClient.new(port, page)
      snapshot = play(first)
      first.close

      second = SparkSpecClient.new(port, page)
      second.join(snapshot: snapshot)
      html = second.await("diff")["patches"].as_a.map(&.["html"].as_s).join
      html.should contain "notes=milk,eggs"
      html.should contain "taps=2"
      html.should contain "scratch=fresh"

      second.event("tap", target: "#{second.root_id}~tally")
      second.await("diff")["patches"][0]["html"].as_s.should contain "taps=3"
      second.close
    end
  end

  it "unmounts the components of the old connection when its socket drops" do
    with_board_server do |port|
      before = SparkRehydrationSpec::Tally.unmounted
      client = SparkSpecClient.new(port, board_page)
      play(client)
      client.close

      wait_until { SparkRehydrationSpec::Tally.unmounted == before + 1 }.should be_true
    end
  end

  it "rejects a tampered snapshot, mounts nothing and lets the client join without it" do
    with_board_server do |port|
      page = board_page
      client = SparkSpecClient.new(port, page)
      snapshot = play(client)
      client.close

      payload, _, signature = snapshot.rpartition('.')
      forged = "#{payload}.#{signature[0] == 'A' ? 'B' : 'A'}#{signature[1..]}"
      second = SparkSpecClient.new(port, page)
      rejected(second, forged)["message"].as_s.should contain "signature"
      second.event("add", text: "x")
      second.await("error")["code"].as_s.should eq "unknown_target"

      second.join
      second.await("diff")["patches"][0]["html"].as_s.should contain "notes="
      second.close
    end
  end

  it "rejects an expired snapshot" do
    with_board_server do |port|
      page = board_page
      client = SparkSpecClient.new(port, page)
      expiring = sign_snapshot(client.root_id, {client.root_id => member("SparkRehydrationSpec::Board", notes: ["old"])}, ttl: 1.minute)

      with_fake_clock do |clock|
        clock.advance(2.minutes)
        rejected(client, expiring)["message"].as_s.should contain "expired"
      end
      client.close
    end
  end

  it "rejects a validly signed snapshot that names another component class" do
    with_board_server do |port|
      client = SparkSpecClient.new(port, board_page)
      evil = sign_snapshot(client.root_id, {client.root_id => member("Kernel::Evil", notes: ["pwned"])})

      rejected(client, evil)["message"].as_s.should contain "Kernel::Evil"
      client.event("add", text: "x")
      client.await("error")["code"].as_s.should eq "unknown_target"
      client.close
    end
  end

  it "rejects a snapshot that exceeds the size limit" do
    with_board_server do |port|
      client = SparkSpecClient.new(port, board_page)
      big = sign_snapshot(client.root_id, {client.root_id => member("SparkRehydrationSpec::Board", notes: ["x" * 600])})
      Azu::Spark.config.max_snapshot_size = 512

      rejected(client, big)["message"].as_s.should contain "too large"
      client.close
    end
  end

  it "does not mount a snapshot of another page, or of the same page under other session claims" do
    with_board_server do |port|
      alice = SparkSpecClient.new(port, board_page)
      snapshot = play(alice)
      alice.close

      bob = SparkSpecClient.new(port, board_page({"user" => "bob"}))
      rejected(bob, snapshot)["message"].as_s.should contain "another page"

      other_session = sign_snapshot(bob.root_id, {bob.root_id => member("SparkRehydrationSpec::Board", notes: ["alice's"])})
      rejected(bob, other_session)["message"].as_s.should contain "another session"
      bob.close
    end
  end
end

describe "Spark failed joins" do
  it "unmount every component of a root whose second child cannot be restored" do
    with_board_server do |port|
      client = SparkSpecClient.new(port, Azu::Spark.render(SparkRehydrationSpec::Pair, session: SparkRehydrationSpec::USER))
      before = SparkRehydrationSpec::Tally.unmounted
      root = client.root_id
      snapshot = sign_snapshot(root, {
        "#{root}~a" => member("SparkRehydrationSpec::Tally", taps: 1),
        "#{root}~b" => member("Kernel::Evil", taps: 1),
      })

      rejected(client, snapshot)
      wait_until { SparkRehydrationSpec::Tally.unmounted == before + 1 }.should be_true
      client.event("tap", target: "#{root}~a")
      client.await("error")["code"].as_s.should eq "unknown_target"
      client.close
    end
  end

  it "does not unmount a live root when the same root is joined again" do
    with_board_server do |port|
      client = SparkSpecClient.new(port, board_page)
      client.join
      client.await("reply")
      client.join
      client.await("error")["code"].as_s.should eq "bad_request"

      client.event("add", text: "still here")
      client.await("diff")["patches"][0]["html"].as_s.should contain "still here"
      client.close
    end
  end

  it "rejects a snapshot whose state is not an object" do
    with_board_server do |port|
      client = SparkSpecClient.new(port, board_page)
      broken = sign_snapshot(client.root_id, {client.root_id => Azu::Spark::Snapshot::Member.new("SparkRehydrationSpec::Board", JSON::Any.new("nope"))})

      rejected(client, broken)["message"].as_s.should contain "not an object"
      client.close
    end
  end
end

describe Azu::Spark::Snapshot do
  secret = SparkRehydrationSpec::SECRET
  members = {"root" => member("Counter", count: 3)}

  it "round trips the members of a page" do
    token = Azu::Spark::Snapshot.sign("root", {"a" => "1"}, members, 1.hour, secret, 4096) || raise "snapshot not signed"
    opened = Azu::Spark::Snapshot.open(token, "root", {"a" => "1"}, secret, 4096)

    opened["root"].type.should eq "Counter"
    opened["root"].state["count"].as_i.should eq 3
  end

  it "refuses an unsupported version" do
    claims = JSON.parse({v: 99, root: "root", sid: Azu::Spark::Snapshot.digest({} of String => String), components: members}.to_json)
    token = Azu::Spark::Token.sign("snapshot", claims, 1.hour, secret)

    expect_raises(Azu::Spark::InvalidSnapshot, /version/) { Azu::Spark::Snapshot.open(token, "root", {} of String => String, secret, 4096) }
  end

  it "does not sign what would exceed the limit" do
    Azu::Spark::Snapshot.sign("root", {} of String => String, members, 1.hour, secret, 50).should be_nil
  end
end
