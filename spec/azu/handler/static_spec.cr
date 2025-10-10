require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::Static do
  describe "initialization" do
    it "initializes with default public directory" do
      with_temp_dir({"test.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir)
        handler.should be_a(Azu::Handler::Static)
      end
    end

    it "initializes with fallthrough enabled" do
      with_temp_dir({"test.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        handler.should be_a(Azu::Handler::Static)
      end
    end

    it "initializes with directory listing enabled" do
      with_temp_dir({"test.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, directory_listing: true)
        handler.should be_a(Azu::Handler::Static)
      end
    end
  end

  describe "basic file serving" do
    it "serves existing files" do
      with_temp_file("Hello, World!", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("Hello, World!")
      end
    end

    it "serves HTML files" do
      with_temp_file("<h1>Test</h1>", "index.html") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/index.html")
        handler.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("<h1>Test</h1>")
      end
    end

    it "serves index.html for directory root" do
      with_temp_dir({"index.html" => "<h1>Home</h1>"}) do |dir|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/")
        handler.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("<h1>Home</h1>")
      end
    end

    it "serves nested files" do
      with_temp_dir({"subdir/file.txt" => "nested content"}) do |dir|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/subdir/file.txt")
        handler.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("nested content")
      end
    end
  end

  describe "MIME type handling" do
    it "sets correct Content-Type for HTML" do
      with_temp_file("<h1>Test</h1>", "test.html") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.html")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/html")
      end
    end

    it "sets correct Content-Type for CSS" do
      with_temp_file("body { color: red; }", "style.css") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/style.css")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/css")
      end
    end

    it "sets correct Content-Type for JavaScript" do
      with_temp_file("console.log('test');", "script.js") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/script.js")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/javascript")
      end
    end

    it "sets correct Content-Type for JSON" do
      with_temp_file("{\"test\": true}", "data.json") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/data.json")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("application/json")
      end
    end
  end

  describe "ETags" do
    it "generates ETag for files" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers.has_key?("ETag").should be_true
        context.response.headers["ETag"].should_not be_empty
      end
    end

    it "returns 304 for matching If-None-Match" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        # First request to get ETag
        context1, io1 = create_context("GET", "/test.txt")
        handler.call(context1)
        etag = context1.response.headers["ETag"]

        # Second request with If-None-Match
        headers = HTTP::Headers.new
        headers["If-None-Match"] = etag
        context2, io2 = create_context("GET", "/test.txt", headers)
        handler.call(context2)

        context2.response.status_code.should eq(304)
        context2.response.headers["Content-Length"]?.should eq("0")
      end
    end

    it "returns full content for non-matching If-None-Match" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        headers = HTTP::Headers.new
        headers["If-None-Match"] = "wrong-etag"
        context, io = create_context("GET", "/test.txt", headers)
        handler.call(context)

        context.response.status_code.should eq(200)
        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("content")
      end
    end
  end

  describe "HTTP methods" do
    it "allows GET requests" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "allows HEAD requests" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("HEAD", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "rejects POST requests by default" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir, fallthrough: false)

        context, io = create_context("POST", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(405)
        context.response.headers["Allow"].should eq("GET, HEAD")
      end
    end

    it "falls through POST requests when fallthrough enabled" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("POST", "/test.txt")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify.call
      end
    end
  end

  describe "security" do
    it "blocks path traversal with null bytes" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test\0.txt")
        handler.call(context)

        context.response.status_code.should eq(400)
      end
    end

    it "normalizes paths to prevent traversal" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        # Try to access file using path traversal
        context, io = create_context("GET", "/../test.txt")
        handler.call(context)

        # Should either block or redirect, not serve the file directly
        context.response.status_code.should_not eq(200)
      end
    end
  end

  describe "fallthrough behavior" do
    it "calls next handler for missing files with fallthrough" do
      with_temp_dir({} of String => String) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("GET", "/missing.txt")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify.call
      end
    end

    it "does not call next handler for missing files without fallthrough" do
      with_temp_dir({} of String => String) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: false)
        next_handler, verify = create_next_handler(0)
        handler.next = next_handler

        context, io = create_context("GET", "/missing.txt")
        handler.call(context)

        # Should not call next handler
        verify.call
      end
    end

    it "calls next handler for directories when fallthrough enabled" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true, directory_listing: false)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("GET", "/subdir/")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify.call
      end
    end
  end

  describe "directory listing" do
    it "shows directory listing when enabled" do
      with_temp_dir({"file1.txt" => "content1", "file2.txt" => "content2"}) do |dir|
        handler = Azu::Handler::Static.new(dir, directory_listing: true)

        context, io = create_context("GET", "/")
        handler.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("file1.txt")
        response.should contain("file2.txt")
        context.response.headers["Content-Type"].should eq("text/html")
      end
    end

    it "calls next handler when directory listing disabled" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, directory_listing: false, fallthrough: true)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("GET", "/subdir/")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify.call
      end
    end
  end

  describe "caching headers" do
    it "sets Cache-Control header" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers.has_key?("Cache-Control").should be_true
      end
    end

    it "sets Accept-Ranges header" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers["Accept-Ranges"].should eq("bytes")
      end
    end

    it "sets X-Content-Type-Options header" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers["X-Content-Type-Options"].should eq("nosniff")
      end
    end
  end

  describe "compression" do
    it "supports gzip encoding for large files" do
      large_content = "x" * 2000  # Above minsize threshold
      with_temp_file(large_content, "large.html") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        headers = HTTP::Headers.new
        headers["Accept-Encoding"] = "gzip"
        context, io = create_context("GET", "/large.html", headers)
        handler.call(context)

        context.response.headers["Content-Encoding"]?.should eq("gzip")
      end
    end

    it "supports deflate encoding for large files" do
      large_content = "x" * 2000
      with_temp_file(large_content, "large.html") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        headers = HTTP::Headers.new
        headers["Accept-Encoding"] = "deflate"
        context, io = create_context("GET", "/large.html", headers)
        handler.call(context)

        context.response.headers["Content-Encoding"]?.should eq("deflate")
      end
    end

    it "does not compress small files" do
      small_content = "small"
      with_temp_file(small_content, "small.html") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        headers = HTTP::Headers.new
        headers["Accept-Encoding"] = "gzip"
        context, io = create_context("GET", "/small.html", headers)
        handler.call(context)

        context.response.headers.has_key?("Content-Encoding").should be_false
      end
    end
  end

  describe "edge cases" do
    it "handles empty files" do
      with_temp_file("", "empty.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/empty.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "handles files with special characters in name" do
      with_temp_file("content", "test file.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test%20file.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "handles trailing slashes in paths" do
      with_temp_file("content", "test.txt") do |dir, filepath|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt/")
        handler.call(context)

        # Should redirect or handle gracefully
        [200, 301, 302, 404].should contain(context.response.status_code)
      end
    end
  end
end

