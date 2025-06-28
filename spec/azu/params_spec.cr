require "../spec_helper"

describe Azu::Params do
  describe "parameter access" do
    it "accesses query parameters" do
      request = HTTP::Request.new("GET", "/test?name=john&age=25")
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("john")
      params["age"].should eq("25")
    end

    it "accesses path parameters" do
      request = HTTP::Request.new("GET", "/users/123")
      request.path_params = {"id" => "123", "type" => "user"}
      params = Azu::Params(TestRequest).new(request)

      params["id"].should eq("123")
      params["type"].should eq("user")
    end

    it "accesses form parameters" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com"
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("john")
      params["email"].should eq("john@example.com")
    end

    it "prioritizes form over path over query" do
      request = HTTP::Request.new("POST", "/users/123?name=query")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form"
      request.path_params = {"name" => "path"}
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("form")
    end
  end

  describe "optional parameter access" do
    it "returns nil for missing parameters" do
      request = HTTP::Request.new("GET", "/test")
      params = Azu::Params(TestRequest).new(request)

      params["missing"]?.should be_nil
    end

    it "returns value for existing parameters" do
      request = HTTP::Request.new("GET", "/test?name=john")
      params = Azu::Params(TestRequest).new(request)

      params["name"]?.should eq("john")
    end
  end

  describe "fetch_all" do
    it "fetches all values for a parameter" do
      request = HTTP::Request.new("GET", "/test?tag=ruby&tag=crystal&tag=web")
      params = Azu::Params(TestRequest).new(request)

      values = params.fetch_all("tag")
      values.should eq(["ruby", "crystal", "web"])
    end

    it "returns single value for path parameter" do
      request = HTTP::Request.new("GET", "/users/123")
      request.path_params = {"id" => "123"}
      params = Azu::Params(TestRequest).new(request)

      values = params.fetch_all("id")
      values.should eq(["123"])
    end

    it "returns empty array for missing parameter" do
      request = HTTP::Request.new("GET", "/test")
      params = Azu::Params(TestRequest).new(request)

      values = params.fetch_all("missing")
      values.should eq([] of String)
    end
  end

  describe "JSON body parsing" do
    it "parses JSON request body" do
      request = HTTP::Request.new("POST", "/api/users")
      request.headers["Content-Type"] = "application/json"
      request.body = "{\"name\": \"john\", \"email\": \"john@example.com\"}"
      params = Azu::Params(TestRequest).new(request)

      params.json.should eq("{\"name\": \"john\", \"email\": \"john@example.com\"}")
    end

    it "handles empty JSON body" do
      request = HTTP::Request.new("POST", "/api/users")
      request.headers["Content-Type"] = "application/json"
      request.body = ""
      params = Azu::Params(TestRequest).new(request)

      params.json.should eq("")
    end
  end

  describe "form data parsing" do
    it "parses URL-encoded form data" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com&age=25"
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("john")
      params["email"].should eq("john@example.com")
      params["age"].should eq("25")
    end

    it "handles empty form data" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = ""
      params = Azu::Params(TestRequest).new(request)

      params.to_h.should eq({} of String => String)
    end
  end

  describe "multipart form data" do
    it "parses multipart form data with files" do
      boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
      request = HTTP::Request.new("POST", "/upload")
      request.headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"

      body = String.build do |str|
        str << "--#{boundary}\r\n"
        str << "Content-Disposition: form-data; name=\"name\"\r\n\r\n"
        str << "john\r\n"
        str << "--#{boundary}\r\n"
        str << "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n"
        str << "Content-Type: text/plain\r\n\r\n"
        str << "file content\r\n"
        str << "--#{boundary}--\r\n"
      end

      request.body = body
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("john")
      params.files["file"].should be_a(Azu::Params::Multipart::File)
      params.files["file"].filename.should eq("test.txt")
    end

    it "handles multipart form data without files" do
      boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"

      body = String.build do |str|
        str << "--#{boundary}\r\n"
        str << "Content-Disposition: form-data; name=\"name\"\r\n\r\n"
        str << "john\r\n"
        str << "--#{boundary}\r\n"
        str << "Content-Disposition: form-data; name=\"email\"\r\n\r\n"
        str << "john@example.com\r\n"
        str << "--#{boundary}--\r\n"
      end

      request.body = body
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("john")
      params["email"].should eq("john@example.com")
      params.files.size.should eq(0)
    end
  end

  describe "to_h" do
    it "converts to hash with all parameters" do
      request = HTTP::Request.new("POST", "/users/123?type=user")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com"
      request.path_params = {"id" => "123"}
      params = Azu::Params(TestRequest).new(request)

      hash = params.to_h

      hash["name"].should eq("john")
      hash["email"].should eq("john@example.com")
      hash["id"].should eq("123")
      hash["type"].should eq("user")
    end

    it "prioritizes form over path over query in hash" do
      request = HTTP::Request.new("POST", "/users/123?name=query")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form"
      request.path_params = {"name" => "path"}
      params = Azu::Params(TestRequest).new(request)

      hash = params.to_h
      hash["name"].should eq("form")
    end
  end

  describe "to_query" do
    it "converts parameters to query string" do
      request = HTTP::Request.new("POST", "/users/123?type=user")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com"
      request.path_params = {"id" => "123"}
      params = Azu::Params(TestRequest).new(request)

      query = params.to_query

      query.should contain("name=john")
      query.should contain("email=john@example.com")
      query.should contain("id=123")
      query.should contain("type=user")
    end
  end

  describe "iteration" do
    it "iterates over all parameters" do
      request = HTTP::Request.new("POST", "/users/123?type=user")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com"
      request.path_params = {"id" => "123"}
      params = Azu::Params(TestRequest).new(request)

      collected = {} of String => String
      params.each do |key, value|
        collected[key] = value
      end

      collected["name"].should eq("john")
      collected["email"].should eq("john@example.com")
      collected["id"].should eq("123")
      collected["type"].should eq("user")
    end
  end

  describe "edge cases" do
    it "handles nil body" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      # request.body is nil by default
      params = Azu::Params(TestRequest).new(request)

      params.to_h.should eq({} of String => String)
    end

    it "handles unknown content type" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/unknown"
      request.body = "some data"
      params = Azu::Params(TestRequest).new(request)

      params.to_h.should eq({} of String => String)
    end

    it "handles malformed form data gracefully" do
      request = HTTP::Request.new("POST", "/submit")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "malformed=data&incomplete"
      params = Azu::Params(TestRequest).new(request)

      # Should not raise an exception
      params.to_h.should be_a(Hash(String, String))
    end
  end
end
