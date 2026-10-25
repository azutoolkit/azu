require "file_utils"
require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

# Exposes the private redirect_path, so the leading slashes are pinned by a unit spec too.
class StaticRedirectProbe < Azu::Handler::Static
  def location(path : String, directory : Bool) : String
    redirect_path(path, directory)
  end
end

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

  describe "default fallthrough" do
    # Placed before the router, a handler that answers 404 for every path that is not a file would hide every route,
    # so the default hands what is not a file to the next handler.
    it "hands a path that is not a file to the next handler" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("GET", "/users/5")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        context.response.status_code.should eq(200)
        verify.call
      end
    end

    it "hands a POST to the next handler instead of answering 405" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)
        next_handler, verify = create_next_handler(1)
        handler.next = next_handler

        context, io = create_context("POST", "/users")
        handler.call(context)

        get_response_body(context, io).should eq("OK")
        context.response.headers["Allow"]?.should be_nil
        verify.call
      end
    end

    it "still serves a file that exists" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)
        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        get_response_body(context, io).should eq("content")
      end
    end

    it "answers 404 and 405 itself with fallthrough: false" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir, fallthrough: false)

        context, _ = create_context("GET", "/users/5")
        handler.call(context)
        context.response.status_code.should eq(404)

        context, _ = create_context("POST", "/users")
        handler.call(context)
        context.response.status_code.should eq(405)
      end
    end
  end

  describe "basic file serving" do
    it "serves existing files" do
      with_temp_file("Hello, World!", "test.txt") do |dir, _|
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
      with_temp_file("<h1>Test</h1>", "index.html") do |dir, _|
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
      with_temp_file("<h1>Test</h1>", "test.html") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.html")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/html")
      end
    end

    it "sets correct Content-Type for CSS" do
      with_temp_file("body { color: red; }", "style.css") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/style.css")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/css")
      end
    end

    it "sets correct Content-Type for JavaScript" do
      with_temp_file("console.log('test');", "script.js") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/script.js")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("text/javascript")
      end
    end

    it "sets correct Content-Type for JSON" do
      with_temp_file("{\"test\": true}", "data.json") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/data.json")
        handler.call(context)

        context.response.headers["Content-Type"].should contain("application/json")
      end
    end
  end

  describe "ETags" do
    it "generates ETag for files" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers.has_key?("ETag").should be_true
        context.response.headers["ETag"].should_not be_empty
      end
    end

    it "returns 304 for matching If-None-Match" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        # First request to get ETag
        context1, _ = create_context("GET", "/test.txt")
        handler.call(context1)
        etag = context1.response.headers["ETag"]

        # Second request with If-None-Match
        headers = HTTP::Headers.new
        headers["If-None-Match"] = etag
        context2, _ = create_context("GET", "/test.txt", headers)
        handler.call(context2)

        context2.response.status_code.should eq(304)
        context2.response.headers["Content-Length"]?.should eq("0")
      end
    end

    it "returns full content for non-matching If-None-Match" do
      with_temp_file("content", "test.txt") do |dir, _|
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
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "allows HEAD requests" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("HEAD", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "rejects POST requests by default" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir, fallthrough: false)

        context, io = create_context("POST", "/test.txt")
        handler.call(context)

        context.response.status_code.should eq(405)
        context.response.headers["Allow"].should eq("GET, HEAD")
      end
    end

    it "falls through POST requests when fallthrough enabled" do
      with_temp_file("content", "test.txt") do |dir, _|
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
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir, fallthrough: false)

        # A client can only send a null byte percent-encoded; the handler must reject it
        # rather than truncate the path at the NUL and serve "test.txt"
        context, io = create_context("GET", "/test%00.txt")
        handler.call(context)

        context.response.status_code.should eq(400)
      end
    end

    it "normalizes paths to prevent traversal" do
      with_temp_file("content", "test.txt") do |dir, _|
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
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers.has_key?("Cache-Control").should be_true
      end
    end

    describe "Cache-Control policy" do
      files = {"app.css" => "a { }", "app-3f2a9c1be4d7.css" => "a { }", "logo.8c1d0e5f.png" => "png"}

      cache_control = ->(handler : Azu::Handler::Static, path : String, headers : HTTP::Headers) do
        context, _ = create_context("GET", path, headers: headers)
        handler.call(context)
        context.response.headers["Cache-Control"]?
      end

      it "makes fingerprinted files immutable for the configured max-age" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir, cache_max_age: 600)

          cache_control.call(handler, "/app-3f2a9c1be4d7.css", HTTP::Headers.new).should eq "public, max-age=600, immutable"
          cache_control.call(handler, "/logo.8c1d0e5f.png", HTTP::Headers.new).should eq "public, max-age=600, immutable"
        end
      end

      it "makes other files revalidate on every use" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)

          cache_control.call(handler, "/app.css", HTTP::Headers.new).should eq "public, no-cache"
        end
      end

      it "takes the policy for other files from the handler" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir, cache_control: "private, max-age=3600")

          cache_control.call(handler, "/app.css", HTTP::Headers.new).should eq "private, max-age=3600"
        end
      end

      it "defaults the fingerprinted max-age to the assets configuration" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          max_age = Azu::CONFIG.assets.cache_max_age

          cache_control.call(handler, "/app-3f2a9c1be4d7.css", HTTP::Headers.new).should eq "public, max-age=#{max_age}, immutable"
        end
      end

      it "treats a date or a number in the name as not being a fingerprint" do
        with_temp_dir({"report-20240101.pdf" => "x", "photo.12345678.jpg" => "x"}) do |dir|
          handler = Azu::Handler::Static.new(dir)

          cache_control.call(handler, "/report-20240101.pdf", HTTP::Headers.new).should eq "public, no-cache"
          cache_control.call(handler, "/photo.12345678.jpg", HTTP::Headers.new).should eq "public, no-cache"
        end
      end

      it "recognizes a fingerprint followed by several extensions" do
        with_temp_dir({"app-3f2a9c1b.min.css" => "x", "app-3f2a9c1b.js.map" => "x"}) do |dir|
          handler = Azu::Handler::Static.new(dir, cache_max_age: 60)

          cache_control.call(handler, "/app-3f2a9c1b.min.css", HTTP::Headers.new).should eq "public, max-age=60, immutable"
          cache_control.call(handler, "/app-3f2a9c1b.js.map", HTTP::Headers.new).should eq "public, max-age=60, immutable"
        end
      end

      it "sends the policy for a directory index too, and on its 304" do
        with_temp_dir({"index.html" => "<p>home</p>"}) do |dir|
          handler = Azu::Handler::Static.new(dir)
          first, _ = create_context("GET", "/")
          handler.call(first)
          first.response.headers["Cache-Control"]?.should eq "public, no-cache"

          headers = HTTP::Headers{"If-None-Match" => first.response.headers["ETag"]}
          cache_control.call(handler, "/", headers).should eq "public, no-cache"
        end
      end

      it "varies on Accept-Encoding, since the stored body depends on it" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          context, _ = create_context("GET", "/app.css")
          handler.call(context)

          context.response.headers["Vary"]?.should eq "Accept-Encoding"
        end
      end

      it "adds Accept-Encoding to a Vary that holds only a longer field, and not twice to one that has it" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          context, _ = create_context("GET", "/app.css")
          context.response.headers["Vary"] = "X-Accept-Encoding"
          handler.call(context)
          context.response.headers["Vary"].split(',').map(&.strip).should eq ["X-Accept-Encoding", "Accept-Encoding"]

          again, _ = create_context("GET", "/app.css")
          again.response.headers["Vary"] = "origin, accept-encoding"
          handler.call(again)
          again.response.headers["Vary"].should eq "origin, accept-encoding"
        end
      end

      it "adds Accept-Encoding to a Vary that is already set, such as CORS's Origin" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          context, _ = create_context("GET", "/app.css")
          context.response.headers["Vary"] = "Origin"
          handler.call(context)

          context.response.headers["Vary"].split(',').map(&.strip).should eq ["Origin", "Accept-Encoding"]
        end
      end

      it "also sends the policy with a 304 so caches keep refreshing it" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          first, _ = create_context("GET", "/app.css")
          handler.call(first)
          etag = first.response.headers["ETag"]

          headers = HTTP::Headers{"If-None-Match" => etag}
          cache_control.call(handler, "/app.css", headers).should eq "public, no-cache"
        end
      end
    end

    it "sets Accept-Ranges header" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers["Accept-Ranges"].should eq("bytes")
      end
    end

    it "sets X-Content-Type-Options header" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt")
        handler.call(context)

        context.response.headers["X-Content-Type-Options"].should eq("nosniff")
      end
    end
  end

  describe "compression" do
    it "supports gzip encoding for large files" do
      large_content = "x" * 2000 # Above minsize threshold
      with_temp_file(large_content, "large.html") do |dir, _|
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
      with_temp_file(large_content, "large.html") do |dir, _|
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
      with_temp_file(small_content, "small.html") do |dir, _|
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
      with_temp_file("", "empty.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/empty.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "handles files with special characters in name" do
      with_temp_file("content", "test file.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test%20file.txt")
        handler.call(context)

        context.response.status_code.should eq(200)
      end
    end

    it "handles trailing slashes in paths" do
      with_temp_file("content", "test.txt") do |dir, _|
        handler = Azu::Handler::Static.new(dir)

        context, io = create_context("GET", "/test.txt/")
        handler.call(context)

        # Should redirect or handle gracefully
        [200, 301, 302, 404].should contain(context.response.status_code)
      end
    end
  end

  describe "a public directory that does not exist" do
    missing = File.join(Dir.tempdir, "azu-static-missing-#{Process.pid}")

    it "passes every request on (regression guard; that no file system call is made is shown by the recheck example below)" do
      FileUtils.rm_rf(missing)
      handler = Azu::Handler::Static.new(missing, fallthrough: true)
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/anything.txt")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "answers 404 without fallthrough (regression guard)" do
      FileUtils.rm_rf(missing)
      handler = Azu::Handler::Static.new(missing, fallthrough: false)
      context, _ = create_context("GET", "/anything.txt")
      handler.call(context)
      context.response.status_code.should eq(404)
    end

    it "still redirects a path that is not in its normal form, and still refuses a null byte (regression guard)" do
      FileUtils.rm_rf(missing)
      handler = Azu::Handler::Static.new(missing, fallthrough: true)

      context, _ = create_context("GET", "/a/../b.txt")
      handler.call(context)
      context.response.status_code.should eq(302)
      context.response.headers["Location"].should eq("/b.txt")

      context, _ = create_context("GET", "/b%00.txt")
      handler.call(context)
      context.response.status_code.should eq(400)
    end

    it "serves a directory created after boot once the missing directory is looked for again" do
      with_fake_clock do |clock|
        FileUtils.rm_rf(missing)
        handler = Azu::Handler::Static.new(missing, fallthrough: true)
        next_handler, _ = create_next_handler(2)
        handler.next = next_handler

        Dir.mkdir_p(missing)
        File.write(File.join(missing, "late.txt"), "created after boot")

        # Within the recheck interval the handler still believes the directory is missing
        context, io = create_context("GET", "/late.txt")
        handler.call(context)
        get_response_body(context, io).should eq("OK")

        clock.advance(Azu::Handler::Static::MISSING_DIRECTORY_RECHECK + 1.millisecond)
        context, io = create_context("GET", "/late.txt")
        handler.call(context)
        get_response_body(context, io).should eq("created after boot")
      ensure
        FileUtils.rm_rf(missing)
      end
    end
  end

  describe "a request for a directory" do
    it "redirects to the path with a single trailing slash" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        context, _ = create_context("GET", "/subdir")
        handler.call(context)
        context.response.status_code.should eq(302)
        context.response.headers["Location"].should eq("/subdir/")
      end
    end

    it "keeps the query string and nested directories" do
      with_temp_dir({"a/b/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        context, _ = create_context("GET", "/a/b?x=1")
        handler.call(context)
        context.response.headers["Location"].should eq("/a/b/?x=1")
      end
    end

    it "normalizes a path with dot segments and still ends a directory with one slash" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        context, _ = create_context("GET", "/x/../subdir")
        handler.call(context)
        context.response.headers["Location"].should eq("/subdir/")
      end
    end

    it "serves a directory that ends in a slash without redirecting to itself" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        context, _ = create_context("GET", "/subdir/")
        Azu::Handler::Static.new(dir).call(context)
        context.response.status_code.should eq(404)
        context.response.headers["Location"]?.should be_nil

        context, io = create_context("GET", "/subdir/")
        Azu::Handler::Static.new(dir, directory_listing: true).call(context)
        context.response.status_code.should eq(200)
        get_response_body(context, io).should contain("file.txt")
      end
    end

    it "does not redirect a file requested with a trailing slash to itself" do
      with_temp_dir({"b.txt" => "content"}) do |dir|
        context, _ = create_context("GET", "/b.txt/")
        Azu::Handler::Static.new(dir).call(context)
        context.response.headers["Location"]?.should be_nil
      end
    end

    it "redirects a path with leading slashes to the same path with one" do
      with_temp_dir({"subdir/file.txt" => "content"}) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: true)
        {"//evil.com" => "/evil.com", "///evil.com/x" => "/evil.com/x", "//subdir" => "/subdir/", "/..//evil.com" => "/evil.com", "/%2Fevil.com" => "/evil.com", "/%2F%2Fevil.com/" => "/evil.com/", "/./%5Cevil.com" => "/evil.com"}.each do |path, location|
          context, _ = create_context("GET", path)
          handler.call(context)
          context.response.headers["Location"]?.should eq location
        end
      end
    end

    it "never builds a protocol-relative Location, whatever path it is given" do
      probe = StaticRedirectProbe.new
      probe.location("//evil.com", false).should eq "/evil.com"
      probe.location("///evil.com", true).should eq "/evil.com/"
      probe.location("/ok/", true).should eq "/ok/"
      probe.location("/ok", false).should eq "/ok"
      probe.location("/\\evil.com", false).should eq "/evil.com"
      probe.location("/\\/evil.com", true).should eq "/evil.com/"
    end
  end

  describe "Range requests" do
    # Every byte differs from its neighbours, so a wrong offset shows up in the body
    content = (0...3000).map { |i| ('a'.ord + i % 26).chr }.join

    serve = ->(range : String) do
      with_temp_file(content, "data.txt") do |dir, _|
        context, io = create_context("GET", "/data.txt", HTTP::Headers{"Range" => range})
        Azu::Handler::Static.new(dir).call(context)
        {context, get_response_body(context, io)}
      end
    end

    {
      "bytes=2000-2009" => {2000, 2009},
      "bytes=1024-1030" => {1024, 1030},
      "bytes=0-0"       => {0, 0},
      "bytes=5-5"       => {5, 5},
      "bytes=2990-"     => {2990, 2999},
      "bytes=-10"       => {2990, 2999},
      "bytes=2990-9999" => {2990, 2999},
    }.each do |range, (first, last)|
      it "serves #{range} as 206 with exactly those bytes" do
        context, body = serve.call(range)

        context.response.status_code.should eq(206)
        context.response.headers["Content-Range"].should eq("bytes #{first}-#{last}/3000")
        context.response.headers["Content-Length"].should eq((last - first + 1).to_s)
        body.should eq(content[first..last])
      end
    end

    it "answers 416 with the total size when the range starts past the end" do
      context, _ = serve.call("bytes=3000-3010")

      context.response.status_code.should eq(416)
      context.response.headers["Content-Range"].should eq("bytes */3000")
    end

    %w(bytes=abc bytes=5-3 bytes=- bytes=0-10,20-30 items=0-5).each do |range|
      it "ignores the unsupported range #{range} and serves the whole file" do
        context, body = serve.call(range)

        context.response.status_code.should eq(200)
        body.should eq(content)
      end
    end
  end
end
