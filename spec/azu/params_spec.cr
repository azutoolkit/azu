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

    it "prioritizes path over query over form" do
      request = HTTP::Request.new("POST", "/users/123?name=query")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form"
      request.path_params = {"name" => "path"}
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("path")
    end

    it "lets the query win over the body when there is no path parameter" do
      request = HTTP::Request.new("POST", "/users?name=query")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form"
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("query")
      params["name"]?.should eq("query")
    end

    it "falls back to the body when neither path nor query has the key" do
      request = HTTP::Request.new("POST", "/users")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form"
      params = Azu::Params(TestRequest).new(request)

      params["name"].should eq("form")
    end

    it "fetch_all follows the same precedence" do
      request = HTTP::Request.new("POST", "/users/5?tag=q1&tag=q2")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "id=1&tag=f1&other=f1&other=f2"
      request.path_params = {"id" => "5"}
      params = Azu::Params(TestRequest).new(request)

      params.fetch_all("id").should eq ["5"]
      params.fetch_all("tag").should eq ["q1", "q2"]
      params.fetch_all("other").should eq ["f1", "f2"]
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

    it "prioritizes path over query over form in hash" do
      request = HTTP::Request.new("POST", "/users/123?name=query&age=7")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=form&age=1&email=form"
      request.path_params = {"name" => "path"}
      params = Azu::Params(TestRequest).new(request)

      hash = params.to_h
      hash["name"].should eq("path")
      hash["age"].should eq("7")
      hash["email"].should eq("form")
    end
  end

  describe "to_query" do
    it "converts parameters to query string" do
      request = HTTP::Request.new("POST", "/users/123?type=user")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=john&email=john@example.com"
      request.path_params = {"id" => "123"}
      params = Azu::Params(TestRequest).new(request)

      HTTP::Params.parse(params.to_query).to_h.should eq({
        "type"  => "user",
        "id"    => "123",
        "name"  => "john",
        "email" => "john@example.com",
      })
    end

    it "keeps a value that contains & and = from smuggling extra parameters" do
      request = HTTP::Request.new("GET", "/test?name=x%26role%3Dadmin")
      params = Azu::Params(TestRequest).new(request)

      HTTP::Params.parse(params.to_query).to_h.should eq({"name" => "x&role=admin"})
    end

    it "round-trips special characters in keys and values" do
      request = HTTP::Request.new("GET", "/test?q=a%20b%2Bc%25d%C3%A9&a%26b%3Dc=1")
      params = Azu::Params(TestRequest).new(request)

      HTTP::Params.parse(params.to_query).to_h.should eq({"q" => "a b+c%dé", "a&b=c" => "1"})
    end

    it "builds the typed request without letting a value set other fields" do
      request = HTTP::Request.new("GET", "/test?name=x%26email%3Devil%40example.com")
      params = Azu::Params(TestRequest).new(request)

      typed = TestRequest.from_query(params.to_query)

      typed.name.should eq("x&email=evil@example.com")
      typed.email.should eq("")
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

  describe "request body limit" do
    around_each do |example|
      original = Azu::CONFIG.upload.max_file_size
      Azu::CONFIG.upload.max_file_size = 1024_u64
      begin
        example.run
      ensure
        Azu::CONFIG.upload.max_file_size = original
      end
    end

    it "refuses an oversized JSON body without reading all of it" do
      body = CountingIO.new(IO::Memory.new(%({"name":"#{"x" * 100_000}"})))
      request = HTTP::Request.new("POST", "/test", HTTP::Headers{"Content-Type" => "application/json"}, body)

      expect_raises(Azu::Response::PayloadTooLarge) { Azu::Params(TestRequest).new(request) }
      body.bytes_read.should be <= 1025
    end

    it "refuses an oversized form body" do
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
      request = HTTP::Request.new("POST", "/test", headers, "name=#{"x" * 5000}")

      expect_raises(Azu::Response::PayloadTooLarge) { Azu::Params(TestRequest).new(request) }
    end

    it "accepts a body within the limit" do
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      request = HTTP::Request.new("POST", "/test", headers, %({"name":"john"}))

      Azu::Params(TestRequest).new(request).typed_request.name.should eq("john")
    end
  end

  describe "typed_request" do
    it "answers 400 for malformed JSON" do
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      request = HTTP::Request.new("POST", "/test", headers, %({"name": ))

      error = expect_raises(Azu::Response::BadRequest) { Azu::Params(TestRequest).new(request).typed_request }
      error.status_code.should eq(400)
    end

    it "answers 400 for a missing required field" do
      request = HTTP::Request.new("GET", "/test?age=3")

      error = expect_raises(Azu::Response::BadRequest) { Azu::Params(StrictRequest).new(request).typed_request }
      error.detail.should contain("name")
    end

    it "answers 400 for a value of the wrong type" do
      request = HTTP::Request.new("GET", "/test?name=a&age=abc")

      expect_raises(Azu::Response::BadRequest) { Azu::Params(StrictRequest).new(request).typed_request }
    end

    it "answers 400 for a multipart body without a boundary" do
      request = HTTP::Request.new("POST", "/test", HTTP::Headers{"Content-Type" => "multipart/form-data"}, "x")

      expect_raises(Azu::Response::BadRequest) { Azu::Params(TestRequest).new(request) }
    end

    it "builds the typed request from valid input" do
      request = HTTP::Request.new("GET", "/test?name=a&age=3")

      typed = Azu::Params(StrictRequest).new(request).typed_request

      {typed.name, typed.age}.should eq({"a", 3})
    end

    it "reaches the client as 400 and 413, not 500" do
      handler = Azu::Handler::Rescuer.new
      handler.next = ->(context : HTTP::Server::Context) { Azu::Params(TestRequest).new(context.request).typed_request; nil }

      malformed = HTTP::Request.new("POST", "/test", HTTP::Headers{"Content-Type" => "application/json"}, %({"name": ))
      malformed_context = HTTP::Server::Context.new(malformed, HTTP::Server::Response.new(IO::Memory.new))
      handler.call(malformed_context)
      malformed_context.response.status_code.should eq(400)

      original = Azu::CONFIG.upload.max_file_size
      Azu::CONFIG.upload.max_file_size = 16_u64
      begin
        large = HTTP::Request.new("POST", "/test", HTTP::Headers{"Content-Type" => "application/json"}, %({"name":"#{"x" * 100}"}))
        large_context = HTTP::Server::Context.new(large, HTTP::Server::Response.new(IO::Memory.new))
        handler.call(large_context)
        large_context.response.status_code.should eq(413)
      ensure
        Azu::CONFIG.upload.max_file_size = original
      end
    end
  end
end

# A request type with required, typed fields
struct StrictRequest
  include Azu::Request

  getter name : String
  getter age : Int32

  def initialize(@name, @age)
  end
end

# An IO that records how many bytes were read from it
class CountingIO < IO
  getter bytes_read = 0

  def initialize(@io : IO)
  end

  def read(slice : Bytes) : Int32
    count = @io.read(slice)
    @bytes_read += count
    count
  end

  def write(slice : Bytes) : Nil
    raise "read-only"
  end
end

# A request body must not be able to change what the URL addressed: `POST /users/5` with `id=1` is user 5.
struct PrecedenceRequest
  include Azu::Request

  getter id : Int64
  getter name : String
  getter admin : Bool = false

  def initialize(@id = 0_i64, @name = "", @admin = false)
  end
end

describe Azu::Params do
  describe "typed_request precedence" do
    it "a form body cannot override a path parameter" do
      request = HTTP::Request.new("POST", "/users/5", HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, "id=1&name=body")
      request.path_params = {"id" => "5"}

      typed = Azu::Params(PrecedenceRequest).new(request).typed_request
      typed.id.should eq 5
      typed.name.should eq "body"
    end

    it "a form body cannot override a query parameter" do
      request = HTTP::Request.new("POST", "/users?id=7", HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, "id=1&name=body")

      Azu::Params(PrecedenceRequest).new(request).typed_request.id.should eq 7
    end

    it "a JSON body cannot override a path parameter" do
      request = HTTP::Request.new("POST", "/users/5", HTTP::Headers{"Content-Type" => "application/json"}, %({"id":1,"name":"body"}))
      request.path_params = {"id" => "5"}

      typed = Azu::Params(PrecedenceRequest).new(request).typed_request
      typed.id.should eq 5
      typed.name.should eq "body"
    end

    it "a JSON body cannot override a query parameter, and the path still wins over the query" do
      request = HTTP::Request.new("POST", "/users/5?id=7&name=q", HTTP::Headers{"Content-Type" => "application/json"}, %({"id":1,"name":"body","admin":false}))
      request.path_params = {"id" => "5"}

      typed = Azu::Params(PrecedenceRequest).new(request).typed_request
      typed.id.should eq 5
      typed.name.should eq "q"
    end

    it "keeps the JSON value type: a boolean field is overridden by a boolean" do
      request = HTTP::Request.new("POST", "/users/5?admin=false", HTTP::Headers{"Content-Type" => "application/json"}, %({"id":5,"name":"x","admin":true}))

      Azu::Params(PrecedenceRequest).new(request).typed_request.admin.should be_false
    end

    it "leaves a JSON body alone when nothing in the URL names one of its keys" do
      request = HTTP::Request.new("POST", "/users/5?other=1", HTTP::Headers{"Content-Type" => "application/json"}, %({"id":3,"name":"body"}))

      typed = Azu::Params(PrecedenceRequest).new(request).typed_request
      typed.id.should eq 3
    end

    it "a JSON array body is left as is" do
      request = HTTP::Request.new("POST", "/users/5", HTTP::Headers{"Content-Type" => "application/json"}, %([1,2]))
      request.path_params = {"id" => "5"}

      expect_raises(Azu::Response::BadRequest) { Azu::Params(PrecedenceRequest).new(request).typed_request }
    end
  end
end
