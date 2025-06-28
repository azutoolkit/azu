require "../spec_helper"

describe "HTTP::Request Extensions" do
  describe "content_type" do
    it "parses JSON content type" do
      request = HTTP::Request.new("POST", "/")
      request.headers["Content-Type"] = "application/json"

      content_type = request.content_type

      content_type.type.should eq("application")
      content_type.sub_type.should eq("json")
    end

    it "parses form data content type" do
      request = HTTP::Request.new("POST", "/")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"

      content_type = request.content_type

      content_type.type.should eq("application")
      content_type.sub_type.should eq("x-www-form-urlencoded")
    end

    it "parses multipart form data content type" do
      request = HTTP::Request.new("POST", "/")
      request.headers["Content-Type"] = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"

      content_type = request.content_type

      content_type.type.should eq("multipart")
      content_type.sub_type.should eq("form-data")
    end

    it "defaults to text/plain when no content type" do
      request = HTTP::Request.new("GET", "/")

      content_type = request.content_type

      content_type.type.should eq("text")
      content_type.sub_type.should eq("plain")
    end
  end

  describe "path_params" do
    it "stores and retrieves path parameters" do
      request = HTTP::Request.new("GET", "/users/123")
      params = {"id" => "123", "type" => "user"}

      request.path_params = params

      request.path_params.should eq(params)
    end

    it "initializes with empty path params" do
      request = HTTP::Request.new("GET", "/")

      request.path_params.should eq({} of String => String)
    end
  end

  describe "accept" do
    it "parses accept header with single type" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "application/json"

      accept = request.accept

      accept.should_not be_nil
      accept.not_nil!.size.should eq(1)
      accept.not_nil!.first.type.should eq("application")
      accept.not_nil!.first.sub_type.should eq("json")
    end

    it "parses accept header with multiple types" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

      accept = request.accept

      accept.should_not be_nil
      accept.not_nil!.size.should eq(4)
      accept.not_nil!.first.type.should eq("text")
      accept.not_nil!.first.sub_type.should eq("html")
    end

    it "sorts by quality value" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html;q=0.8,application/json;q=0.9,text/plain;q=1.0"

      accept = request.accept

      accept.should_not be_nil
      accept.not_nil!.size.should eq(3)
      # Should be sorted by quality value (highest first)
      accept.not_nil!.first.sub_type.should eq("plain") # q=1.0
      accept.not_nil![1].sub_type.should eq("json")     # q=0.9
      accept.not_nil![2].sub_type.should eq("html")     # q=0.8
    end

    it "handles missing accept header" do
      request = HTTP::Request.new("GET", "/")

      accept = request.accept

      accept.should be_nil
    end

    it "handles empty accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = ""

      accept = request.accept

      accept.should be_nil
    end

    it "caches accept header parsing" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "application/json"

      accept1 = request.accept
      accept2 = request.accept

      accept1.should eq(accept2)
    end
  end

  describe "accept header edge cases" do
    it "handles malformed accept header gracefully" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "invalid,content,type"

      # Should not raise an exception - just test that it doesn't crash
      begin
        request.accept
        # If we get here, no exception was raised
        true.should be_true
      rescue
        fail "Should not raise exception for malformed accept header"
      end
    end

    it "handles accept header with spaces" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html, application/json"

      accept = request.accept

      accept.should_not be_nil
      accept.not_nil!.size.should eq(2)
    end

    it "handles accept header with parameters" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html; charset=utf-8, application/json"

      accept = request.accept

      accept.should_not be_nil
      accept.not_nil!.size.should eq(2)
    end
  end
end
