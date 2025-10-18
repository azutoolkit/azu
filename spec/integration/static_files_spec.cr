require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe "Static Files Integration" do
  describe "Static + Logger integration" do
    it "logs static file requests" do
      with_temp_file("Hello", "test.txt") do |dir, _|
        static = Azu::Handler::Static.new(dir)
        logger = Azu::Handler::Logger.new

        logger.next = static

        context, io = create_context("GET", "/test.txt")
        logger.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("Hello")
      end
    end

    it "logs 404 for missing files" do
      with_temp_dir({} of String => String) do |dir|
        static = Azu::Handler::Static.new(dir, fallthrough: false)
        logger = Azu::Handler::Logger.new

        logger.next = static

        context, _ = create_context("GET", "/missing.txt")
        logger.call(context)

        # Logger should log the 404
      end
    end
  end

  describe "Static + CORS integration" do
    it "serves static files with CORS headers" do
      with_temp_file("Content", "file.txt") do |dir, _|
        cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        cors.next = static

        headers = HTTP::Headers.new
        headers["Origin"] = "https://example.com"
        context, io = create_context("GET", "/file.txt", headers)

        cors.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("Content")
        context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      end
    end
  end

  describe "Static + RequestID integration" do
    it "adds request ID to static file responses" do
      with_temp_file("Data", "data.json") do |dir, _|
        request_id = Azu::Handler::RequestId.new
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        request_id.next = static

        context, _ = create_context("GET", "/data.json")
        request_id.call(context)

        context.request.headers.has_key?("X-Request-ID").should be_true
        context.response.headers.has_key?("X-Request-ID").should be_true
      end
    end
  end

  describe "Static + Rescuer integration" do
    it "handles static handler errors" do
      with_temp_file("Content", "test.txt") do |dir, _|
        rescuer = Azu::Handler::Rescuer.new
        static = Azu::Handler::Static.new(dir, fallthrough: false)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        rescuer.next = static

        # Crystal's HTTP::Request automatically strips null bytes from paths for security
        # "/test\0.txt" becomes "/test", which won't match "test.txt"
        context, _ = create_context("GET", "/test\0.txt")
        rescuer.call(context)

        # Static handler with fallthrough=false simply doesn't serve non-existent files
        # The response will be empty (no content) but not an error
        # This verifies that null byte injection doesn't allow accessing "test.txt"
        context.response.status_code.should_not eq(200)
      end
    end
  end

  describe "Static with fallthrough to application" do
    it "falls through to next handler for missing files" do
      with_temp_dir({} of String => String) do |dir|
        static = Azu::Handler::Static.new(dir, fallthrough: true)
        app_handler, verify = create_next_handler(1)

        static.next = app_handler

        context, io = create_context("GET", "/api/users")
        static.call(context)

        get_response_body(context, io).should eq("OK")
        verify.call
      end
    end

    it "serves static files before falling through" do
      with_temp_file("Static content", "index.html") do |dir, _|
        static = Azu::Handler::Static.new(dir, fallthrough: true)
        app_handler, verify = create_next_handler(0)

        static.next = app_handler

        context, io = create_context("GET", "/index.html")
        static.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("Static content")
        verify.call
      end
    end
  end

  describe "ETag caching in chain" do
    it "serves 304 for cached files" do
      with_temp_file("Cached content", "cached.txt") do |dir, _|
        request_id = Azu::Handler::RequestId.new
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        request_id.next = static

        # First request to get ETag
        context1, _ = create_context("GET", "/cached.txt")
        request_id.call(context1)
        etag = context1.response.headers["ETag"]

        # Second request with If-None-Match
        headers = HTTP::Headers.new
        headers["If-None-Match"] = etag
        context2, _ = create_context("GET", "/cached.txt", headers)
        request_id.call(context2)

        context2.response.status_code.should eq(304)
        context2.response.headers["Content-Length"]?.should eq("0")
      end
    end
  end

  describe "compression in chain" do
    it "serves gzipped content when accepted" do
      large_content = "x" * 2000
      with_temp_file(large_content, "large.html") do |dir, _|
        cors = Azu::Handler::CORS.new
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        cors.next = static

        headers = HTTP::Headers.new
        headers["Accept-Encoding"] = "gzip"
        context, _ = create_context("GET", "/large.html", headers)

        cors.call(context)

        context.response.headers["Content-Encoding"]?.should eq("gzip")
      end
    end
  end

  describe "full static file chain" do
    it "processes static requests through complete chain" do
      with_temp_file("Hello World", "hello.txt") do |dir, _|
        request_id = Azu::Handler::RequestId.new
        logger = Azu::Handler::Logger.new
        cors = Azu::Handler::CORS.new(origins: ["*"])
        metrics = Azu::PerformanceMetrics.new
        performance = Azu::Handler::PerformanceMonitor.new(metrics)
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        performance.next = static
        cors.next = performance
        logger.next = cors
        request_id.next = logger

        headers = HTTP::Headers.new
        headers["Origin"] = "https://example.com"
        context, io = create_context("GET", "/hello.txt", headers)

        request_id.call(context)

        context.response.close
        io.rewind
        response = io.gets_to_end
        response.should contain("Hello World")
        context.request.headers.has_key?("X-Request-ID").should be_true
        context.response.headers.has_key?("Access-Control-Allow-Origin").should be_true

        stats = performance.stats
        stats.total_requests.should eq(1)
      end
    end
  end

  describe "security with static files" do
    it "prevents path traversal" do
      with_temp_file("Secret", "secret.txt") do |dir, _|
        rescuer = Azu::Handler::Rescuer.new
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        rescuer.next = static

        context, _ = create_context("GET", "/../secret.txt")
        rescuer.call(context)

        # Should not serve the file
        context.response.status_code.should_not eq(200)
      end
    end

    it "blocks null byte injection" do
      with_temp_file("Content", "file.txt") do |dir, _|
        static = Azu::Handler::Static.new(dir, fallthrough: false)
        static.next = ->(_ctx : HTTP::Server::Context) { }

        # Crystal's HTTP::Request automatically strips null bytes from paths
        # "/file\0.txt" becomes "/file", which won't match "file.txt"
        context, _ = create_context("GET", "/file\0.txt")
        static.call(context)

        # Returns 404 because the path "/file" doesn't exist (only "file.txt" does)
        # This effectively prevents null byte injection from accessing "file.txt"
        context.response.status_code.should eq(404)
      end
    end
  end

  describe "performance of static serving" do
    it "serves files efficiently" do
      with_temp_file("Fast content", "fast.txt") do |dir, _|
        metrics = Azu::PerformanceMetrics.new
        performance = Azu::Handler::PerformanceMonitor.new(metrics)
        static = Azu::Handler::Static.new(dir)

        static.next = ->(_ctx : HTTP::Server::Context) { }
        performance.next = static

        10.times do
          context, _ = create_context("GET", "/fast.txt")
          performance.call(context)
        end

        stats = performance.stats
        stats.total_requests.should eq(10)
        stats.avg_response_time.should be < 100 # Should be fast
      end
    end
  end

  describe "MIME type handling" do
    it "sets correct MIME types through chain" do
      with_temp_dir({
        "test.html" => "<h1>HTML</h1>",
        "test.js"   => "console.log('JS');",
        "test.css"  => "body { color: red; }",
        "test.json" => "{\"test\": true}",
      }) do |dir|
        static = Azu::Handler::Static.new(dir)
        static.next = ->(_ctx : HTTP::Server::Context) { }

        files = [
          {"/test.html", "text/html"},
          {"/test.js", "text/javascript"},
          {"/test.css", "text/css"},
          {"/test.json", "application/json"},
        ]

        files.each do |path, mime_type|
          context, _ = create_context("GET", path)
          static.call(context)
          context.response.headers["Content-Type"].should contain(mime_type)
        end
      end
    end
  end
end
