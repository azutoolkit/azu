require "../../spec_helper"
require "../../support/spark_helpers"

module SparkComponentSpec
  enum Filter
    All
    Done
  end

  struct SignupRequest
    include Azu::Request

    getter name : String
    getter email : String

    def initialize(@name : String = "", @email : String = "")
    end

    validate name, presence: true, message: "Name is required"
    validate email, presence: true, message: "Email is required"
  end

  class Counter < Azu::Spark::Component
    mountable

    prop label : String = "Clicks"
    state count : Int32 = 0, persist: true
    state step : Int32 = 1
    state filter : Filter = Filter::All
    state tags : Array(String) = [] of String
    state signup : SignupRequest = SignupRequest.new
    state seen : Array(String) = [] of String

    getter mounts = [] of Bool

    def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
      @mounts << socket.connected?
      self.count = params.fetch("start", Int32, 0)
      socket.reject!("blocked") if socket.session["role"]? == "banned"
    end

    def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
      @seen << "#{message.topic}:#{message.payload}"
    end

    event def increment : Nil
      self.count += step
    end

    event def set_step(value : Int32) : Nil
      self.step = value
    end

    event def retag(tags : Array(String), filter : Filter = Filter::Done, note : String? = nil) : Nil
      assign tags: tags, filter: filter
    end

    event def validate(signup : SignupRequest) : Nil
      self.signup = signup
    end

    event def explode : Nil
      raise "boom"
    end

    def helper_not_an_event : Nil
      self.count = 999
    end

    def render
      div class: "counter" do
        h2 "#{label}: #{count}"
        button "+", **spark_click(:increment, debounce: 100, id: 7)
        input **spark_change(:set_step, throttle: 50), type: "text", name: "step", value: step.to_s
        span errors_on(signup, :name).join(",") unless signup.name.presence
      end
    end
  end
end

describe Azu::Spark::Component do
  describe "props and state" do
    it "exposes typed assigns" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter, label: "Hits") do |view|
        view.assigns[:label].should eq "Hits"
        view.assigns[:count].should eq 0
        view.assigns[:step].should eq 1
      end
    end

    it "re-renders when an event changes state" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.html.should contain "Clicks: 0"

        view.trigger("increment")
        view.trigger("increment")

        view.html.should contain "Clicks: 2"
        view.component.count.should eq 2
      end
    end

    it "marks only assigned state as changed" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.component.socket.clear_changes
        view.component.count = 0
        view.component.socket.changed?.should be_false

        view.component.count = 3
        view.component.socket.changed.should eq Set{"count"}
      end
    end

    it "mounts first without and then with a live connection" do
      html = Azu::Spark.render(SparkComponentSpec::Counter, label: "Static")

      html.should contain "Static: 0"
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.component.mounts.should eq [true]
      end
    end
  end

  describe "events" do
    it "coerces payload values to the declared parameter types" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.trigger("set_step", value: "5")
        view.trigger("increment")
        view.component.count.should eq 5

        view.trigger("retag", tags: ["a", "b"])
        view.component.tags.should eq ["a", "b"]
        view.component.filter.should eq SparkComponentSpec::Filter::Done
        view.trigger("retag", tags: "single", filter: "all")
        view.component.tags.should eq ["single"]
        view.component.filter.should eq SparkComponentSpec::Filter::All
      end
    end

    it "builds Azu::Request parameters from the payload and exposes their validation errors" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.trigger("validate", name: "", email: "a@b.c")

        view.html.should contain "Name is required"
        view.component.signup.valid?.should be_false
      end
    end

    it "rejects payloads that do not fit the declared types" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        expect_raises(Azu::Spark::BadRequest, /value/) { view.trigger("set_step", value: "many") }
        expect_raises(Azu::Spark::BadRequest, /missing parameter 'value'/) { view.trigger("set_step") }
        expect_raises(Azu::Spark::BadRequest) { view.trigger("retag", tags: ["a"], filter: "bogus") }
        view.component.step.should eq 1
      end
    end

    it "dispatches only methods declared with event def" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        %w(helper_not_an_event mount render count= initialize handle_event __spark_render).each do |name|
          expect_raises(Azu::Spark::UnknownEvent) { view.trigger(name) }
        end
        view.component.count.should eq 0
      end
    end

    it "lets handler failures reach the caller without corrupting the view" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        expect_raises(Exception, "boom") { view.trigger("explode") }
        view.trigger("increment")
        view.component.count.should eq 1
      end
    end
  end

  describe "bindings" do
    it "renders spark attributes with modifiers and payload values" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.html.should contain "spark-click='increment'"
        view.html.should contain "spark-debounce='100'"
        view.html.should contain "spark-value-id='7'"
        view.html.should contain "spark-change='set_step'"
        view.html.should contain "spark-throttle='50'"
      end
    end

    it "wraps the component in an element carrying its identity" do
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        view.html.should start_with "<div id='root' data-spark-id='root' data-spark-view='SparkComponentSpec::Counter'>"
      end
    end
  end

  describe "mounting from a page" do
    it "embeds a signed join token and the rendered view" do
      html = Azu::Spark.render(SparkComponentSpec::Counter, label: "Page")

      html.should contain "data-spark-root"
      html.should match /data-spark-token='[\w\-]+\.[\w\-]+'/
      html.should contain "Page: 0"
    end

    it "escapes prop values" do
      Azu::Spark.render(SparkComponentSpec::Counter, label: "<script>x</script>").should_not contain "<script>x"
    end
  end

  describe "persisted state" do
    it "restores persisted state from a snapshot of an earlier mount" do
      snapshot = Azu::Spark::Testing.mount(SparkComponentSpec::Counter) do |view|
        3.times { view.trigger("increment") }
        view.snapshot
      end

      snapshot.should_not be_nil
      Azu::Spark::Testing.mount(SparkComponentSpec::Counter, snapshot: snapshot) do |view|
        view.component.count.should eq 3
        view.html.should contain "Clicks: 3"
      end
    end

    it "ignores a snapshot that was issued for another view" do
      snapshot = Azu::Spark::Testing.mount(SparkComponentSpec::Counter, &.trigger("increment").snapshot)

      Azu::Spark::Testing.mount(SparkComponentSpec::Counter, snapshot: snapshot.try(&.sub(/\.(\w)/) { |_, match| match[1] == "x" ? ".y" : ".x" })) do |view|
        view.component.count.should eq 0
      end
    end
  end

  describe "detached sockets" do
    it "ignore PubSub, timers and browser pushes, which need a live connection" do
      socket = Azu::Spark::Socket.detached

      socket.subscribe("topic")
      socket.send_after(1.second, "later")
      socket.every(1.second, "tick")
      socket.send_info("now")
      socket.push_event("noop")

      socket.changed?.should be_false
    end
  end

  describe "navigation and browser events" do
    it "only redirects to paths of the application" do
      socket = Azu::Spark::Socket.detached
      socket.redirect("/home")
      expect_raises(ArgumentError) { socket.redirect("https://evil.example") }
      expect_raises(ArgumentError) { socket.redirect("//evil.example") }
      expect_raises(ArgumentError) { socket.redirect("/\\evil.example") }
    end
  end
end
