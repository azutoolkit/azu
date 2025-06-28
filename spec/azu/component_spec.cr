require "../spec_helper"

class TestComponent
  include Azu::Component

  property event_received = false
  property event_name = ""
  property event_data = ""

  def content
    div { text "Test Component" }
  end

  def on_event(name, data)
    @event_received = true
    @event_name = name
    @event_data = data
  end
end

class CounterComponent
  include Azu::Component

  property count = 0

  def content
    div do
      text "Count: #{@count}"
      button(onclick: "increment") { text "Increment" }
    end
  end

  def on_event(name, data)
    case name
    when "increment"
      @count += 1
      refresh
    end
  end
end

describe Azu::Component do
  describe "component lifecycle" do
    it "generates unique ID for each component" do
      component1 = TestComponent.new
      component2 = TestComponent.new

      component1.id.should_not eq(component2.id)
      component1.id.should be_a(String)
      component2.id.should be_a(String)
    end

    it "tracks mounted and connected state" do
      component = TestComponent.new

      component.mounted?.should be_false
      component.connected?.should be_false
      component.disconnected?.should be_true

      component.mounted = true
      component.connected = true

      component.mounted?.should be_true
      component.connected?.should be_true
      component.disconnected?.should be_false
    end

    it "tracks component age" do
      component = TestComponent.new
      initial_age = component.age

      sleep 10.milliseconds

      component.age.should be > initial_age
    end
  end

  describe "component mounting" do
    it "mounts component and adds to registry" do
      component = TestComponent.mount

      component.mounted?.should be_true
      Azu::Spark::COMPONENTS[component.id].should eq(component)
    end

    it "calls mount lifecycle method" do
      component = TestComponent.new
      component.mount # This should be callable
      # No assertion needed as mount is empty by default
    end

    it "calls unmount lifecycle method" do
      component = TestComponent.new
      component.unmount # This should be callable
      # No assertion needed as unmount is empty by default
    end
  end

  describe "component rendering" do
    it "renders component with spark view wrapper" do
      component = TestComponent.new
      rendered = component.render

      rendered.should contain("data-spark-view=\"#{component.id}\"")
      rendered.should contain("Test Component")
    end

    it "generates HTML content" do
      component = TestComponent.new
      component.content # Generate the content

      component.to_s.should contain("Test Component")
    end
  end

  describe "component events" do
    it "handles events" do
      component = TestComponent.new

      component.on_event("test_event", "test_data")

      component.event_received.should be_true
      component.event_name.should eq("test_event")
      component.event_data.should eq("test_data")
    end
  end

  describe "component refresh" do
    it "refreshes component content" do
      component = CounterComponent.new
      component.content # Generate initial content
      initial_content = component.to_s

      component.count = 5
      component.refresh # This calls content internally

      component.to_s.should_not eq(initial_content)
      component.to_s.should contain("Count: 5")
    end

    it "refreshes with block" do
      component = CounterComponent.new

      component.refresh do
        component.count = 10
      end

      component.to_s.should contain("Count: 10")
    end
  end

  describe "periodic tasks" do
    it "runs periodic tasks when connected" do
      component = CounterComponent.new
      component.connected = true

      task_run = false
      component.every(50.milliseconds) do
        task_run = true
      end

      sleep 100.milliseconds

      task_run.should be_true
    end

    it "stops periodic tasks when disconnected" do
      component = CounterComponent.new
      component.connected = true

      task_count = 0
      component.every(10.milliseconds) do
        task_count += 1
        component.connected = false if task_count >= 2
      end

      sleep 100.milliseconds

      # Should only run a few times before stopping
      task_count.should be <= 3
    end
  end

  describe "socket management" do
    it "sets socket connection" do
      component = TestComponent.new
      # Create a mock WebSocket using IO::Memory instead of real connection
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)

      component.socket = socket
      component.socket.should eq(socket)
    end
  end
end
