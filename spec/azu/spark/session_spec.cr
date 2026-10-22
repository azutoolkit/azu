require "../../spec_helper"
require "../../support/spark_helpers"

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
end
