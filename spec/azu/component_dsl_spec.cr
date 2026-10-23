require "../spec_helper"

module Azu::ComponentDslSpec
  class Signup
    include Azu::Request

    getter email : String = ""
    validate email, match: /@/, message: "must be an email"

    def initialize(@email = "")
    end
  end

  class Counter
    include Azu::Component

    prop label : String = "Count"
    prop step : Int32 = 1
    state count : Int32 = 0
    state errors : Hash(String, Array(String)) = Hash(String, Array(String)).new
    state log : Array(String) = [] of String

    getter refreshes = 0
    getter mounts = 0

    on :increment do
      self.count += step
    end

    on :set do |event|
      self.count = event.value.to_i
    end

    on :twice do
      self.count += 1
      self.count += 1
    end

    on :reset do
      assign count: 0, log: [] of String
    end

    on :validate, Signup do |form|
      self.errors = form_errors(form)
    end

    on :note do |event|
      self.log = log + [event["text"]]
    end

    on :mutate do
      log << "in place"
      changed!
    end

    after_mount do
      @mounts += 1
      subscribe "counters"
    end

    def refresh
      @refreshes += 1
      super
    end

    def content
      div do
        h2 { text "#{label}: #{count}" }
        button(spark_click: :increment, spark_value: "1") { text "+" }
      end
    end
  end

  class Doubler < Counter
    on :double do
      self.count = count * 2
    end
  end

  class Manual
    include Azu::Component

    getter seen = [] of String

    def on_event(name, data)
      @seen << "#{name}:#{data}"
    end
  end

  class Strict
    include Azu::Component

    prop name : String

    def content
      div { text name }
    end
  end
end

describe "Azu::Component DSL" do
  it "builds a keyword constructor from props and states" do
    counter = Azu::ComponentDslSpec::Counter.new(label: "Hits", count: 5)
    counter.label.should eq "Hits"
    counter.step.should eq 1
    counter.count.should eq 5
  end

  it "requires props without a default" do
    Azu::ComponentDslSpec::Strict.new(name: "x").name.should eq "x"
  end

  it "mounts with props" do
    counter = Azu::ComponentDslSpec::Counter.mount(label: "Mounted")
    counter.mounted?.should be_true
    Azu::Spark.components.get(counter.id).should eq counter
    Azu::Spark.components.delete(counter.id)
  end

  it "dispatches on-handlers and re-renders" do
    counter = Azu::ComponentDslSpec::Counter.new(step: 2)
    counter.connected = true
    counter.on_event("increment", "{}")
    counter.count.should eq 2
    counter.refreshes.should eq 1
  end

  it "re-renders once per event however many states change" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.connected = true
    counter.on_event("twice", "")
    counter.count.should eq 2
    counter.refreshes.should eq 1
  end

  it "does not re-render when nothing changed" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.connected = true
    counter.on_event("set", {value: "0"}.to_json)
    counter.refreshes.should eq 0
  end

  it "re-renders after in-place mutation with changed!" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.connected = true
    counter.on_event("mutate", "")
    counter.log.should eq ["in place"]
    counter.refreshes.should eq 1
  end

  it "reads event values and form fields" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.on_event("set", {value: "41"}.to_json)
    counter.count.should eq 41
    counter.on_event("note", {text: "hello"}.to_json)
    counter.log.should eq ["hello"]
  end

  it "assigns several states at once" do
    counter = Azu::ComponentDslSpec::Counter.new(count: 9)
    counter.on_event("reset", "")
    counter.count.should eq 0
  end

  it "parses typed payloads and exposes validation errors" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.on_event("validate", {email: "nope"}.to_json)
    counter.errors.should eq({"email" => ["must be an email"]})
    counter.on_event("validate", {email: "a@b.co"}.to_json)
    counter.errors.should be_empty
  end

  it "ignores unknown events" do
    counter = Azu::ComponentDslSpec::Counter.new
    counter.on_event("nothing", "")
    counter.count.should eq 0
  end

  it "keeps hand-written on_event working" do
    manual = Azu::ComponentDslSpec::Manual.new
    manual.on_event("click", "x")
    manual.seen.should eq ["click:x"]
  end

  it "supports handlers in subclasses on top of the parent's" do
    sub = Azu::ComponentDslSpec::Doubler.new(count: 3)
    sub.on_event("double", "")
    sub.count.should eq 6
    sub.on_event("increment", "")
    sub.count.should eq 7
  end

  it "runs after_mount and joins topics" do
    counter = Azu::ComponentDslSpec::Counter.new
    Azu::Spark.components.register(counter.id, counter)
    counter.connected = true
    counter.mount
    counter.mounts.should eq 1

    Azu::Spark.broadcast("counters", "set", {value: "99"}.to_json).should be >= 1
    counter.count.should eq 99

    counter.unmount
    Azu::Spark.components.publish("counters", "set", {value: "5"}.to_json)
    counter.count.should eq 99
    Azu::Spark.components.delete(counter.id)
  end

  it "renders spark attributes into the markup" do
    counter = Azu::ComponentDslSpec::Counter.new
    html = counter.render
    html.should contain "spark-click='increment'"
    html.should contain "spark-value='1'"
    html.should contain "Count: 0"
  end

  it "ships a dependency-free client script" do
    tag = Azu::Spark.javascript_tag("/live")
    tag.should contain "data-spark-path=\"/live\""
    tag.should contain "spark-submit"
    tag.should_not contain "unpkg"
    tag.should_not contain "jquery"
  end
end

describe Azu::Component::Event do
  it "reads scalar, object and plain payloads" do
    Azu::Component::Event.new(%({"value":"a","n":"1"})).value.should eq "a"
    Azu::Component::Event.new("true").checked?.should be_true
    Azu::Component::Event.new(%({"value":true})).checked?.should be_true
    Azu::Component::Event.new("not json").value.should eq "not json"
    Azu::Component::Event.new(%({"a":"1","b":2})).to_h.should eq({"a" => "1", "b" => "2"})
    Azu::Component::Event.new("{}")["x"]?.should be_nil
  end
end
