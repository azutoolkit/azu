require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

# Test handler that tracks calls
class TrackingHandler
  include HTTP::Handler

  getter call_count : Int32 = 0
  getter contexts : Array(HTTP::Server::Context) = [] of HTTP::Server::Context

  def call(context : HTTP::Server::Context)
    @call_count += 1
    @contexts << context
    call_next(context)
  end

  def reset
    @call_count = 0
    @contexts.clear
  end
end

# Test handler that sets a header
class HeaderHandler
  include HTTP::Handler

  def initialize(@header_name : String, @header_value : String)
  end

  def call(context : HTTP::Server::Context)
    context.response.headers[@header_name] = @header_value
    call_next(context)
  end
end

# Test handler that writes response body
class BodyHandler
  include HTTP::Handler

  def initialize(@body : String)
  end

  def call(context : HTTP::Server::Context)
    context.response.print @body
  end
end

describe Azu::HandlerPipeline do
  describe "#use" do
    it "adds a handler to the pipeline" do
      pipeline = Azu::HandlerPipeline.new
      handler = TrackingHandler.new

      pipeline.use(handler)

      pipeline.size.should eq(1)
    end

    it "supports chaining" do
      pipeline = Azu::HandlerPipeline.new
        .use(TrackingHandler.new)
        .use(TrackingHandler.new)

      pipeline.size.should eq(2)
    end

    it "adds a block handler" do
      pipeline = Azu::HandlerPipeline.new
      pipeline.use { |ctx| ctx.response.headers["X-Test"] = "value" }

      pipeline.size.should eq(1)
    end
  end

  describe "#use_if" do
    it "adds handler when condition is true" do
      pipeline = Azu::HandlerPipeline.new
        .use_if(true, TrackingHandler.new)

      pipeline.size.should eq(1)
    end

    it "does not add handler when condition is false" do
      pipeline = Azu::HandlerPipeline.new
        .use_if(false, TrackingHandler.new)

      pipeline.size.should eq(0)
    end
  end

  describe "#build" do
    it "raises EmptyPipelineError when pipeline is empty" do
      pipeline = Azu::HandlerPipeline.new

      expect_raises(Azu::HandlerPipeline::EmptyPipelineError) do
        pipeline.build
      end
    end

    it "returns first handler" do
      first_handler = TrackingHandler.new
      second_handler = TrackingHandler.new

      handler = Azu::HandlerPipeline.new
        .use(first_handler)
        .use(second_handler)
        .build

      handler.should be(first_handler)
    end

    it "links handlers in chain" do
      first_handler = TrackingHandler.new
      second_handler = TrackingHandler.new

      Azu::HandlerPipeline.new
        .use(first_handler)
        .use(second_handler)
        .build

      # Verify chain by checking that calling first handler invokes both
      context, _ = create_context("GET", "/test")
      first_handler.call(context)

      first_handler.call_count.should eq(1)
      second_handler.call_count.should eq(1)
    end

    it "executes handlers in order" do
      order = [] of String

      handler = Azu::HandlerPipeline.new
        .use { |_| order << "first" }
        .use { |_| order << "second" }
        .use { |_| order << "third" }
        .build

      context, _ = create_context("GET", "/test")
      handler.call(context)

      order.should eq(["first", "second", "third"])
    end

    it "passes context through the chain" do
      handler = Azu::HandlerPipeline.new
        .use(HeaderHandler.new("X-First", "1"))
        .use(HeaderHandler.new("X-Second", "2"))
        .use(BodyHandler.new("OK"))
        .build

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.headers["X-First"].should eq("1")
      context.response.headers["X-Second"].should eq("2")
      get_response_body(context, io).should eq("OK")
    end
  end

  describe "#build?" do
    it "returns nil when pipeline is empty" do
      pipeline = Azu::HandlerPipeline.new
      pipeline.build?.should be_nil
    end

    it "returns handler when pipeline is not empty" do
      pipeline = Azu::HandlerPipeline.new
        .use(TrackingHandler.new)

      pipeline.build?.should_not be_nil
    end
  end

  describe "#empty?" do
    it "returns true for new pipeline" do
      pipeline = Azu::HandlerPipeline.new
      pipeline.empty?.should be_true
    end

    it "returns false after adding handler" do
      pipeline = Azu::HandlerPipeline.new
        .use(TrackingHandler.new)

      pipeline.empty?.should be_false
    end
  end

  describe "#clear" do
    it "removes all handlers" do
      pipeline = Azu::HandlerPipeline.new
        .use(TrackingHandler.new)
        .use(TrackingHandler.new)

      pipeline.clear
      pipeline.size.should eq(0)
    end

    it "supports chaining" do
      pipeline = Azu::HandlerPipeline.new
        .use(TrackingHandler.new)
        .clear
        .use(TrackingHandler.new)

      pipeline.size.should eq(1)
    end
  end
end
