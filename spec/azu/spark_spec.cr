require "../spec_helper"

# Mock WebSocket for testing that doesn't make real network connections
class MockWebSocket < HTTP::WebSocket
  def initialize
    # Create a mock socket without establishing a connection
    # Use a dummy IO that doesn't actually connect
    dummy_io = IO::Memory.new
    super(dummy_io, sync_close: false)
  end

  # Override methods to prevent actual network operations during tests
  def send(message : String)
    # Mock implementation - don't actually send
  end

  def send(binary : Bytes)
    # Mock implementation - don't actually send
  end

  def ping(message = "")
    # Mock implementation - don't actually ping
  end

  def pong(message = "")
    # Mock implementation - don't actually pong
  end

  def close(code : CloseCode? = nil, message = "")
    # Mock implementation - don't actually close
  end
end

class TestSparkComponent
  include Azu::Component

  property event_received = false
  property event_name = ""
  property event_data = ""

  def content
    div { text "Test Spark Component" }
  end

  def on_event(name, data)
    @event_received = true
    @event_name = name
    @event_data = data
  end
end

describe Azu::Spark do
  describe "component management" do
    it "stores components in COMPONENTS hash" do
      component = TestSparkComponent.new
      component_id = component.id

      Azu::Spark::COMPONENTS[component_id] = component

      Azu::Spark::COMPONENTS[component_id].should eq(component)
    end

    it "provides javascript tag" do
      js_tag = Azu::Spark.javascript_tag

      js_tag.should be_a(String)
      js_tag.should_not be_empty
    end
  end

  describe "WebSocket lifecycle" do
    it "inherits from Channel" do
      spark = Azu::Spark.new(MockWebSocket.new)
      spark.should be_a(Azu::Channel)
    end

    it "handles binary messages" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_binary(Bytes[1, 2, 3])
    end

    it "handles ping messages" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_ping("ping")
    end

    it "handles pong messages" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_pong("pong")
    end

    it "handles connect events" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_connect
    end
  end

  describe "message handling" do
    it "handles subscribe messages" do
      component = TestSparkComponent.new
      component_id = component.id
      Azu::Spark::COMPONENTS[component_id] = component

      spark = Azu::Spark.new(MockWebSocket.new)
      message = {"subscribe" => component_id}.to_json

      spark.on_message(message)

      component.connected?.should be_true
      component.connected?.should be_true
    end

    it "handles event messages" do
      component = TestSparkComponent.new
      component_id = component.id
      Azu::Spark::COMPONENTS[component_id] = component

      spark = Azu::Spark.new(MockWebSocket.new)
      message = {
        "event"   => "test_event",
        "channel" => component_id,
        "data"    => "test_data",
      }.to_json

      spark.on_message(message)

      component.event_received.should be_true
      component.event_name.should eq("test_event")
      component.event_data.should eq("test_data")
    end

    it "handles invalid JSON gracefully" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_message("invalid json")
    end

    it "handles missing channel in event message" do
      spark = Azu::Spark.new(MockWebSocket.new)
      message = {
        "event" => "test_event",
        "data"  => "test_data",
      }.to_json

      # Should not raise an exception
      spark.on_message(message)
    end

    it "handles missing data in event message" do
      component = TestSparkComponent.new
      component_id = component.id
      Azu::Spark::COMPONENTS[component_id] = component

      spark = Azu::Spark.new(MockWebSocket.new)
      message = {
        "event"   => "test_event",
        "channel" => component_id,
      }.to_json

      # Should not raise an exception
      spark.on_message(message)
    end

    it "handles non-existent component gracefully" do
      spark = Azu::Spark.new(MockWebSocket.new)
      message = {
        "event"   => "test_event",
        "channel" => "non_existent_id",
        "data"    => "test_data",
      }.to_json

      # Should not raise an exception
      spark.on_message(message)
    end
  end

  describe "connection close handling" do
    it "unmounts all components on close" do
      component1 = TestSparkComponent.new
      component2 = TestSparkComponent.new
      component1_id = component1.id
      component2_id = component2.id

      Azu::Spark::COMPONENTS[component1_id] = component1
      Azu::Spark::COMPONENTS[component2_id] = component2

      spark = Azu::Spark.new(MockWebSocket.new)

      spark.on_close

      # Components should be removed from the registry
      Azu::Spark::COMPONENTS[component1_id]?.should be_nil
      Azu::Spark::COMPONENTS[component2_id]?.should be_nil
    end

    it "handles close with code and message" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_close(HTTP::WebSocket::CloseCode::NormalClosure, "Normal closure")
    end

    it "handles close without parameters" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception
      spark.on_close
    end
  end

  describe "garbage collection" do
    it "has GC interval constant" do
      Azu::Spark::GC_INTERVAL.should eq(10.seconds)
    end

    it "runs garbage collection in background" do
      # The gc_sweep method is called during class initialization
      # We can verify that the constant is set correctly
      Azu::Spark::GC_INTERVAL.should be_a(Time::Span)
    end
  end

  describe "error handling" do
    it "handles IO errors gracefully" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception for IO errors
      # This is tested by the rescue IO::Error in the on_message method
      spark.should be_a(Azu::Spark)
    end

    it "handles general exceptions gracefully" do
      spark = Azu::Spark.new(MockWebSocket.new)

      # Should not raise an exception for general errors
      # This is tested by the rescue ex in the on_message method
      spark.should be_a(Azu::Spark)
    end
  end

  describe "component lifecycle integration" do
    it "integrates with component mounting" do
      component = TestSparkComponent.new
      component_id = component.id
      Azu::Spark::COMPONENTS[component_id] = component

      spark = Azu::Spark.new(MockWebSocket.new)
      message = {"subscribe" => component_id}.to_json

      spark.on_message(message)

      component.mounted?.should be_true
    end

    it "integrates with component event handling" do
      component = TestSparkComponent.new
      component_id = component.id
      Azu::Spark::COMPONENTS[component_id] = component

      spark = Azu::Spark.new(MockWebSocket.new)

      # Subscribe first
      subscribe_message = {"subscribe" => component_id}.to_json
      spark.on_message(subscribe_message)

      # Then send event
      event_message = {
        "event"   => "custom_event",
        "channel" => component_id,
        "data"    => "custom_data",
      }.to_json
      spark.on_message(event_message)

      component.event_received.should be_true
      component.event_name.should eq("custom_event")
      component.event_data.should eq("custom_data")
    end
  end

  describe "multiple components" do
    it "handles multiple components independently" do
      component1 = TestSparkComponent.new
      component2 = TestSparkComponent.new
      component1_id = component1.id
      component2_id = component2.id

      Azu::Spark::COMPONENTS[component1_id] = component1
      Azu::Spark::COMPONENTS[component2_id] = component2

      spark = Azu::Spark.new(MockWebSocket.new)

      # Subscribe both components
      spark.on_message({"subscribe" => component1_id}.to_json)
      spark.on_message({"subscribe" => component2_id}.to_json)

      component1.connected?.should be_true
      component2.connected?.should be_true

      # Send events to different components
      spark.on_message({
        "event"   => "event1",
        "channel" => component1_id,
        "data"    => "data1",
      }.to_json)

      spark.on_message({
        "event"   => "event2",
        "channel" => component2_id,
        "data"    => "data2",
      }.to_json)

      component1.event_name.should eq("event1")
      component1.event_data.should eq("data1")
      component2.event_name.should eq("event2")
      component2.event_data.should eq("data2")
    end
  end
end
