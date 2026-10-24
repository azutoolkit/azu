require "../../spec_helper"
require "../../support/spark_helpers"
require "../../support/slow_pub_sub"

module SparkSessionSpec
  record Todo, id : Int32, title : String

  class Item < Azu::Spark::Component
    container "li", class: "item"

    prop todo : Todo
    state pinned : Bool = false

    class_getter unmounted = [] of Int32

    def unmount(socket : Azu::Spark::Socket) : Nil
      Item.unmounted << todo.id
    end

    event def pin : Nil
      self.pinned = !pinned
    end

    def render
      span "#{todo.title}#{pinned ? " (pinned)" : ""}"
      button "x", **spark_click(:remove, target: :parent, id: todo.id)
    end
  end

  class Board < Azu::Spark::Component
    state todos : Array(Todo) = [Todo.new(1, "one"), Todo.new(2, "two")]
    state clicks : Int32 = 0
    state heard : Array(String) = [] of String
    state title : String = "Board"

    def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
      socket.subscribe("board") if socket.connected?
      socket.every(20.milliseconds, "tick") if params.has_key?("ticking")
    end

    def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
      self.heard = heard + ["#{message.topic}/#{message.payload}"]
    end

    event def add(title : String) : Nil
      self.todos = todos + [Todo.new(todos.max_of(&.id) + 1, title)]
    end

    event def remove(id : Int32) : Nil
      self.todos = todos.reject { |todo| todo.id == id }
    end

    event def click : Nil
      self.clicks += 1
    end

    event def retitle(value : String) : Nil
      self.title = value
    end

    event def flash_and_go : Nil
      socket.put_flash("info", "Saved")
      socket.push_event("saved", {id: 5})
      socket.redirect("/done", replace: true)
    end

    def render
      title do
        text title
      end
      span "clicks=#{clicks}"
      span "flash=#{socket.flash["info"]?}"
      ul do
        todos.each { |todo| live Item, key: todo.id.to_s, todo: todo }
      end
    end
  end

  class Looping < Azu::Spark::Component
    state ticks : Int32 = 0

    def render
      self.ticks += 1
      span ticks.to_s
    end
  end
end

# A session that is not connected, so mounting the board subscribes to nothing.
private def cold_session : Azu::Spark::Session
  session = Azu::Spark::Session.new(Azu::Spark::ConnectionInfo.detached, false) { |_| }
  session.start(SparkSessionSpec::Board.new, "root", {} of String => String, Azu::Spark::Params.new)
  session
end

describe "Spark::Session#subscribe" do
  it "subscribes once, and no event returns before the backend confirmed, for two events on a cold topic" do
    with_slow_pub_sub do |backend|
      session = cold_session
      returned = ::Channel(Time::Instant).new(2)
      2.times { spawn { session.subscribe("root", "cold"); returned.send(Time.instant) } }

      2.times { returned.receive.should be >= (backend.confirmed_at || Time.instant + 1.hour) }
      backend.topics.count("cold").should eq 1
      backend.subscriber_count.should eq 1
    end
  end

  it "makes a second caller fail with the first one's error, and lets a later call try anew" do
    with_slow_pub_sub do |backend|
      backend.fail_first = true
      session = cold_session
      failure = ::Channel(Exception?).new(1)
      spawn do
        session.subscribe("root", "flaky")
        failure.send(nil)
      rescue ex
        failure.send(ex)
      end
      wait_until { backend.subscribe_calls == 1 }.should be_true

      expect_raises(Exception, "the backend failed") { session.subscribe("root", "flaky") }

      failure.receive.should_not be_nil
      backend.topics.count("flaky").should eq 1
      session.subscribe("root", "flaky")
      backend.topics.count("flaky").should eq 2
      backend.subscriber_count.should eq 1
    end
  end

  it "releases the reservation when the subscribe raises, so a retry works" do
    with_slow_pub_sub do |backend|
      backend.fail_first = true
      session = cold_session

      expect_raises(Exception, "the backend failed") { session.subscribe("root", "retry") }
      session.subscribe("root", "retry")

      backend.subscriber_count.should eq 1
    end
  end

  it "honours an unsubscribe that arrives while the subscribe is in flight" do
    with_slow_pub_sub do |backend|
      session = cold_session
      spawn { session.subscribe("root", "gone") }
      wait_until { backend.subscribe_calls == 1 }.should be_true

      session.unsubscribe("root", "gone")

      wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true
    end
  end

  it "ends unsubscribed when subscribe, subscribe, unsubscribe happen during one wait" do
    with_slow_pub_sub do |backend|
      session = cold_session
      finished = ::Channel(Nil).new(2)
      2.times { spawn { session.subscribe("root", "order"); finished.send(nil) } }
      wait_until { backend.subscribe_calls == 1 }.should be_true
      Fiber.yield

      session.unsubscribe("root", "order")

      2.times { finished.receive }
      backend.topics.count("order").should eq 1
      backend.subscriber_count.should eq 0
    end
  end

  it "subscribes anew when the last call was a subscribe after an unsubscribe during the wait" do
    with_slow_pub_sub do |backend|
      session = cold_session
      spawn { session.subscribe("root", "again") }
      wait_until { backend.subscribe_calls == 1 }.should be_true

      session.unsubscribe("root", "again")
      session.subscribe("root", "again")

      backend.topics.count("again").should eq 2
      wait_until { backend.subscriber_count == 1 }.should be_true
    end
  end

  it "lets the component mounted again after an unsubscribe in flight subscribe for itself" do
    with_slow_pub_sub do |backend|
      session = cold_session
      spawn { session.subscribe("root", "t") }
      wait_until { backend.subscribe_calls == 1 }.should be_true
      session.unsubscribe("root", "t")
      session.close
      session.start(SparkSessionSpec::Board.new, "root", {} of String => String, Azu::Spark::Params.new)

      session.subscribe("root", "t")

      backend.topics.count("t").should eq 2
      wait_until { backend.subscriber_count == 1 }.should be_true
    end
  end

  it "fails every waiter with the one backend call when the backend keeps failing" do
    with_slow_pub_sub(200.milliseconds) do |backend|
      backend.fail_always = true
      session = cold_session
      outcomes = ::Channel(Exception?).new(4)
      4.times do
        spawn do
          session.subscribe("root", "down")
          outcomes.send(nil)
        rescue ex
          outcomes.send(ex)
        end
      end

      4.times { outcomes.receive.should_not be_nil }
      backend.topics.count("down").should eq 1
    end
  end

  it "does not subscribe a waiter that was woken by an unmount" do
    with_slow_pub_sub do |backend|
      session = cold_session
      finished = ::Channel(Nil).new(2)
      2.times { spawn { session.subscribe("root", "bye"); finished.send(nil) } }
      wait_until { backend.subscribe_calls == 1 }.should be_true
      Fiber.yield

      session.close

      2.times { finished.receive }
      backend.topics.count("bye").should eq 1
      backend.subscriber_count.should eq 0
    end
  end

  it "gives a component mounted again under the same id its own subscription" do
    with_slow_pub_sub do |backend|
      session = cold_session
      spawn { session.subscribe("root", "t") }
      wait_until { backend.subscribe_calls == 1 }.should be_true
      session.close
      session.start(SparkSessionSpec::Board.new, "root", {} of String => String, Azu::Spark::Params.new)

      wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true # the old one was cancelled
      session.subscribe("root", "t")

      backend.subscriber_count.should eq 1
    end
  end

  it "does not hang when the backend subscribes again from the subscribing fiber" do
    with_slow_pub_sub do |backend|
      session = cold_session
      backend.on_subscribe = -> { session.subscribe("root", "again"); nil }
      finished = ::Channel(Nil).new(1)
      spawn { session.subscribe("root", "again"); finished.send(nil) }

      select
      when finished.receive
      when timeout(2.seconds)
        fail "a re-entrant subscribe waited for itself"
      end
    end
  end

  it "cancels a subscription that finishes after the component was unmounted" do
    with_slow_pub_sub do |backend|
      session = cold_session
      spawn { session.subscribe("root", "late") }
      wait_until { backend.subscribe_calls == 1 }.should be_true

      session.close

      wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true
    end
  end
end

private def board_session(root : String) : Azu::Spark::Session
  session = Azu::Spark::Session.new(Azu::Spark::ConnectionInfo.detached, true) { |_| }
  session.start(SparkSessionSpec::Board.new, root, {} of String => String, Azu::Spark::Params.new)
  session
end

private def mount_board(**options, &)
  Azu::Spark::Testing.mount(SparkSessionSpec::Board, **options) { |view| yield view }
end

describe Azu::Spark::Session do
  describe "child components" do
    it "renders children inside the parent with their own element" do
      mount_board do |view|
        view.html.should contain "<li class='item' id='root~1' data-spark-id='root~1' data-spark-view='SparkSessionSpec::Item'>"
        view.html.should contain "<span>one</span>"
        view.html.should contain "<span>two</span>"
        view.components(SparkSessionSpec::Item).map(&.todo.id).sort!.should eq [1, 2]
      end
    end

    it "sends the parent with empty slots and each child as its own patch, parents first" do
      mount_board do |view|
        view.patches.map(&.id).should eq ["root", "root~1", "root~2"]

        parent = view.patches.first.html
        parent.should contain "<li class='item' id='root~1' data-spark-id='root~1' data-spark-view='SparkSessionSpec::Item' data-spark-slot></li>"
        parent.should_not contain "<span>one</span>"
        view.patches[1].html.should contain "<span>one</span>"
      end
    end

    it "mounts new children and unmounts removed ones" do
      SparkSessionSpec::Item.unmounted.clear
      mount_board do |view|
        view.trigger("add", title: "three")
        view.components(SparkSessionSpec::Item).map(&.todo.title).sort!.should eq ["one", "three", "two"]

        view.trigger("remove", id: 1)
        view.components(SparkSessionSpec::Item).map(&.todo.id).sort!.should eq [2, 3]
        SparkSessionSpec::Item.unmounted.should eq [1]
      end
    end

    it "patches only the component whose state changed" do
      mount_board do |view|
        view.patches.clear
        item = view.components(SparkSessionSpec::Item).find! { |candidate| candidate.todo.id == 2 }

        view.trigger("pin", target: item)

        view.patches.map(&.id).should eq ["root~2"]
        view.html.should contain "two (pinned)"
        view.html.should contain "<span>one</span>"
      end
    end

    it "updates a child in place when the parent passes new props" do
      mount_board do |view|
        first = view.components(SparkSessionSpec::Item).find! { |candidate| candidate.todo.id == 1 }
        first_id = first.id
        view.component.todos = [SparkSessionSpec::Todo.new(1, "renamed"), SparkSessionSpec::Todo.new(2, "two")]
        view.trigger("click")

        view.components(SparkSessionSpec::Item).find! { |candidate| candidate.id == first_id }.todo.title.should eq "renamed"
        view.html.should contain "<span>renamed</span>"
        view.patches.map(&.id).last(2).should eq ["root", "root~1"]
      end
    end

    it "unmounts every descendant when the view closes" do
      SparkSessionSpec::Item.unmounted.clear
      mount_board(&.close)
      SparkSessionSpec::Item.unmounted.sort!.should eq [1, 2]
    end
  end

  describe "change detection" do
    it "does not resend HTML that did not change" do
      mount_board do |view|
        view.trigger("retitle", value: "Board")
        patch_count = view.patches.size

        view.trigger("retitle", value: "Board")

        view.patches.size.should eq patch_count
        view.trigger("retitle", value: "Renamed")
        view.patches.size.should eq patch_count + 1
        view.patches.last.html.should contain "<title>Renamed</title>"
      end
    end
  end

  describe "async messages" do
    after_each { Azu::PubSub.shutdown }

    it "delivers PubSub broadcasts to handle_info and renders them" do
      mount_board do |view|
        view.component.heard.should be_empty

        view.broadcast("board", "hello")
        view.broadcast("elsewhere", "ignored")

        view.component.heard.should eq ["board/hello"]
      end
    end

    it "cancels subscriptions when the view closes" do
      backend = Azu::PubSub.backend.as(Azu::PubSub::Memory)
      view = Azu::Spark::Testing.mount(SparkSessionSpec::Board)
      backend.subscriber_count.should eq 1

      view.close

      backend.subscriber_count.should eq 0
    end

    it "delivers timers until the view closes and then stops them" do
      view = Azu::Spark::Testing.mount(SparkSessionSpec::Board, params: {"ticking" => "1"})
      view.settle(100.milliseconds)
      ticks = view.component.heard.size
      ticks.should be >= 2

      view.close
      sleep 80.milliseconds
      view.settle
      view.component.heard.size.should eq ticks
    end
  end

  describe "server pushes" do
    it "carries flash messages, browser events and redirects" do
      mount_board do |view|
        view.trigger("flash_and_go")

        view.html.should contain "flash=Saved"
        view.pushes.map(&.name).should eq ["saved"]
        view.pushes.first.payload["id"].as_i.should eq 5
        view.redirect.should eq Azu::Spark::Update::Redirect.new("/done", true)
      end
    end
  end

  describe "limits" do
    it "refuses more components than the connection may own" do
      config = Azu::Spark::Configuration.new
      config.max_components = 2
      session = Azu::Spark::Session.new(Azu::Spark::ConnectionInfo.detached, true, config) { |_| }
      component = SparkSessionSpec::Board.new

      expect_raises(Azu::Spark::LimitExceeded) do
        session.start(component, "root", {} of String => String, Azu::Spark::Params.new)
      end
    end

    it "bounds rendering loops caused by state changes inside render" do
      session = Azu::Spark::Session.new(Azu::Spark::ConnectionInfo.detached, true) { |_| }

      expect_raises(Azu::Spark::Error, /render loop/) do
        session.start(SparkSessionSpec::Looping.new, "root", {} of String => String, Azu::Spark::Params.new)
      end
    end
  end

  describe "event delivery" do
    it "accepts an event id once and ignores that id and every older one" do
      session = board_session("a")

      session.accept("a", 5_i64, nil).should be_true
      session.accept("a", 5_i64, nil).should be_false
      session.accept("a", 3_i64, nil).should be_false
      session.accept("a", 6_i64, nil).should be_true
    end

    it "keeps one position per root, so ids of another root do not shadow it" do
      session = board_session("a")
      session.start(SparkSessionSpec::Board.new, "b", {} of String => String, Azu::Spark::Params.new)

      session.accept("a", 7_i64, nil).should be_true
      session.accept("b", 4_i64, nil).should be_true
      session.accept("b", 4_i64, nil).should be_false
      session.accept("a", 4_i64, nil).should be_false
    end

    it "addresses the root through any component below it" do
      session = board_session("a")

      session.accept("a~1", 2_i64, nil).should be_true
      session.accept("a", 2_i64, nil).should be_false
    end

    it "accepts every event of a client that sends no ids" do
      session = board_session("a")

      3.times { session.accept("a", nil, nil).should be_true }
    end

    it "keeps nothing per event: an id is refused however many came after it" do
      session = board_session("a")
      (1_i64..20_000_i64).each { |eid| session.accept("a", eid, nil).should be_true }

      session.accept("a", 1_i64, nil).should be_false
      session.accept("a", 19_999_i64, nil).should be_false
      session.accept("a", 20_001_i64, nil).should be_true
    end

    it "raises UnknownTarget for a component that does not exist" do
      expect_raises(Azu::Spark::UnknownTarget) { board_session("a").accept("nope", 1_i64, nil) }
    end

    it "ignores the generation of a root that has none" do
      board_session("a").accept("a", 1_i64, "whatever").should be_true
    end
  end
end
