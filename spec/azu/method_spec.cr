require "../spec_helper"

describe Azu::Method do
  describe "method parsing" do
    it "parses GET method" do
      Azu::Method.parse("get").should eq(Azu::Method::Get)
      Azu::Method.parse("GET").should eq(Azu::Method::Get)
    end

    it "parses POST method" do
      Azu::Method.parse("post").should eq(Azu::Method::Post)
      Azu::Method.parse("POST").should eq(Azu::Method::Post)
    end

    it "parses PUT method" do
      Azu::Method.parse("put").should eq(Azu::Method::Put)
      Azu::Method.parse("PUT").should eq(Azu::Method::Put)
    end

    it "parses PATCH method" do
      Azu::Method.parse("patch").should eq(Azu::Method::Patch)
      Azu::Method.parse("PATCH").should eq(Azu::Method::Patch)
    end

    it "parses DELETE method" do
      Azu::Method.parse("delete").should eq(Azu::Method::Delete)
      Azu::Method.parse("DELETE").should eq(Azu::Method::Delete)
    end

    it "parses HEAD method" do
      Azu::Method.parse("head").should eq(Azu::Method::Head)
      Azu::Method.parse("HEAD").should eq(Azu::Method::Head)
    end

    it "parses OPTIONS method" do
      Azu::Method.parse("options").should eq(Azu::Method::Options)
      Azu::Method.parse("OPTIONS").should eq(Azu::Method::Options)
    end

    it "parses CONNECT method" do
      Azu::Method.parse("connect").should eq(Azu::Method::Connect)
      Azu::Method.parse("CONNECT").should eq(Azu::Method::Connect)
    end

    it "parses TRACE method" do
      Azu::Method.parse("trace").should eq(Azu::Method::Trace)
      Azu::Method.parse("TRACE").should eq(Azu::Method::Trace)
    end

    it "parses WebSocket method" do
      Azu::Method.parse("websocket").should eq(Azu::Method::WebSocket)
      Azu::Method.parse("WEBSOCKET").should eq(Azu::Method::WebSocket)
    end
  end

  describe "method values" do
    it "has correct string representations" do
      Azu::Method::Get.to_s.should eq("Get")
      Azu::Method::Post.to_s.should eq("Post")
      Azu::Method::Put.to_s.should eq("Put")
      Azu::Method::Patch.to_s.should eq("Patch")
      Azu::Method::Delete.to_s.should eq("Delete")
      Azu::Method::Head.to_s.should eq("Head")
      Azu::Method::Options.to_s.should eq("Options")
      Azu::Method::Connect.to_s.should eq("Connect")
      Azu::Method::Trace.to_s.should eq("Trace")
      Azu::Method::WebSocket.to_s.should eq("WebSocket")
    end
  end

  describe "add_options?" do
    it "returns true for methods that should add OPTIONS" do
      Azu::Method::Get.add_options?.should be_true
      Azu::Method::Post.add_options?.should be_true
      Azu::Method::Put.add_options?.should be_true
      Azu::Method::Patch.add_options?.should be_true
      Azu::Method::Delete.add_options?.should be_true
    end

    it "returns false for methods that should not add OPTIONS" do
      Azu::Method::Trace.add_options?.should be_false
      Azu::Method::Connect.add_options?.should be_false
      Azu::Method::Options.add_options?.should be_false
      Azu::Method::Head.add_options?.should be_false
    end
  end

  describe "method comparison" do
    it "compares methods correctly" do
      Azu::Method::Get.should eq(Azu::Method::Get)
      Azu::Method::Post.should_not eq(Azu::Method::Get)
    end

    it "can be used in case statements" do
      method = Azu::Method::Post

      result = case method
               when .get?
                 "GET"
               when .post?
                 "POST"
               when .put?
                 "PUT"
               else
                 "OTHER"
               end

      result.should eq("POST")
    end
  end

  describe "method ordering" do
    it "maintains correct order" do
      # Verify that methods are ordered as expected
      methods = [
        Azu::Method::WebSocket,
        Azu::Method::Connect,
        Azu::Method::Delete,
        Azu::Method::Get,
        Azu::Method::Head,
        Azu::Method::Options,
        Azu::Method::Patch,
        Azu::Method::Post,
        Azu::Method::Put,
        Azu::Method::Trace,
      ]

      methods.size.should eq(10)
      methods.first.should eq(Azu::Method::WebSocket)
      methods.last.should eq(Azu::Method::Trace)
    end
  end

  describe "method validation" do
    it "validates HTTP methods" do
      # Test that all standard HTTP methods are supported
      standard_methods = %w(get post put patch delete head options connect trace)

      standard_methods.each do |method_name|
        method = Azu::Method.parse(method_name)
        method.should be_a(Azu::Method)
      end
    end

    it "handles WebSocket method" do
      # Test that WebSocket method is supported
      method = Azu::Method.parse("websocket")
      method.should eq(Azu::Method::WebSocket)
    end
  end
end
