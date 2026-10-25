require "file_utils"
require "../../spec_helper"
require "../../support/integration_helpers"
require "../../../benchmark/micro/harness"

include IntegrationHelpers

# Exposes the private redirect_path, so the leading slashes are pinned by a unit spec too.
class StaticRedirectProbe < Azu::Handler::Static
  def location(path : String, directory : Bool) : String
    redirect_path(path, directory)
  end
end

# What a routed path falls through to; it answers nothing, so measured bytes are Static's own.
private class StaticNoopNext
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
  end
end

# Bytes Static allocates per request for `path` under `dir`, after a first call that memoizes request.path (a
# connection's request has parsed it already). The clock does not move, so the directory is not looked at again.
private def static_bytes(dir : String, path : String) : Float64
  with_fake_clock do
    handler = Azu::Handler::Static.new(dir, fallthrough: true)
    handler.next = StaticNoopNext.new
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(IO::Memory.new))
    handler.call(context)
    HotPath.bytes_per_call { handler.call(context) }
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

    it "compresses the other text types the handler serves, in either case of the extension" do
      %w(app.mjs data.CSV subs.vtt site.webmanifest feed.rss feed.atom app.js.map data.jsonld page.xhtml font.eot).each do |name|
        with_temp_file("x" * 2000, name) do |dir, _|
          context, _ = create_context("GET", "/#{name}", HTTP::Headers{"Accept-Encoding" => "gzip"})
          Azu::Handler::Static.new(dir).call(context)

          {name, context.response.headers["Content-Encoding"]?}.should eq({name, "gzip"})
        end
      end
    end

    it "does not compress archives or images" do
      %w(a.zip a.png a.mp4 a.gz).each do |name|
        with_temp_file("x" * 2000, name) do |dir, _|
          context, _ = create_context("GET", "/#{name}", HTTP::Headers{"Accept-Encoding" => "gzip"})
          Azu::Handler::Static.new(dir).call(context)

          context.response.headers.has_key?("Content-Encoding").should be_false
        end
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

    it "redirects //evil.com to a path on this site, not to another host (regression guard)" do
      FileUtils.rm_rf(missing)
      context, _ = create_context("GET", "//evil.com")
      Azu::Handler::Static.new(missing, fallthrough: true).call(context)

      context.response.status_code.should eq(302)
      context.response.headers["Location"].should eq("/evil.com")
    end

    {% if flag?(:preview_mt) %}
      # GC.stats.total_bytes counts every thread, so a window would include the other workers' garbage
      pending "takes the full route for a path with a backslash, which except reads as a separator"
    {% else %}
      it "takes the full route for a path with a backslash, which except reads as a separator" do
        FileUtils.rm_rf(missing)
        # Only the full route allocates; with fallthrough it then passes the path on as well
        static_bytes(missing, "/templates\\x.txt").should be > 0
      end
    {% end %}
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

  describe "except" do
    files = {
      "templates/layout.jinja"     => "SECRET-LAYOUT",
      "templates/a/b.jinja"        => "SECRET-B",
      "templates/note.txt"         => "SECRET-NOTE",
      "templates/sub/index.html"   => "SECRET-INDEX",
      "templates-x/a.txt"          => "PUBLIC-X",
      "templates.txt"              => "PUBLIC-DOT",
      "app.css"                    => "PUBLIC-CSS",
      "other/templates/shared.txt" => "PUBLIC-NESTED",
      "index.html"                 => "PUBLIC-HOME",
      # Directories and files whose odd names exist on disk, so a request for them is served unless refused.
      "templates /a/b.txt"       => "SECRET-SPACE",
      "templates./a/b.txt"       => "SECRET-DOT",
      "templates\\a\\b.txt"      => "SECRET-BACKSLASH",
      "a\\..\\templates/a/b.txt" => "SECRET-DOTDOT-BACKSLASH",
    }

    on_disk = {
      "/templates%20/a/b.txt"     => "SECRET-SPACE",
      "/templates./a/b.txt"       => "SECRET-DOT",
      "/templates\\a\\b.txt"      => "SECRET-BACKSLASH",
      "/a\\..\\templates/a/b.txt" => "SECRET-DOTDOT-BACKSLASH",
      "/templates/note.txt"       => "SECRET-NOTE",
      "/%74emplates/note.txt"     => "SECRET-NOTE",
    }

    # What a request answers: the status, the body, and whether the next handler (the router) was reached.
    serve = ->(handler : Azu::Handler::Static, method : String, path : String) do
      reached = false
      handler.next = ->(ctx : HTTP::Server::Context) { reached = true; ctx.response.print "NEXT" }
      context, io = create_context(method, path)
      handler.call(context)
      body = get_response_body(context, io)
      {context.response.status_code, body, reached, context.response.headers["Location"]?}
    end

    blocked = [
      "/templates/layout.jinja", "/templates/a/b.jinja", "/Templates/a/b.jinja", "/TEMPLATES/A/B.JINJA",
      "/%74emplates/a/b.jinja", "/templates%2Fa/b.jinja", "/templates/a%2Fb.jinja", "/%54EMPLATES/layout.jinja",
      "//templates/a/b.jinja", "/a/../templates/a/b.jinja", "/./templates/a/b.jinja", "/templates/./a/b.jinja",
      "/templates/../templates/a/b.jinja", "/other/../templates/layout.jinja", "/templates/a/../layout.jinja",
      "/templates\\a\\b.jinja", "/a\\..\\templates/a/b.jinja", "/templates./a/b.jinja", "/templates%20/a/b.jinja",
      "/templates\\a\\b.txt", "/a\\..\\templates/a/b.txt", "/templates./a/b.txt", "/templates%20/a/b.txt",
      "/templates", "/templates/", "/templates%2F", "/templates/sub", "/templates/sub/", "/templates/sub/index.html",
      "/%2e%2e/templates/layout.jinja",
    ]

    blocked.each do |path|
      it "does not serve #{path} (falls through)" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir, except: ["/templates"])
          status, body, reached, location = serve.call(handler, "GET", path)

          body.should_not contain("SECRET")
          reached.should be_true
          body.should eq("NEXT")
          location.should be_nil
        end
      end
    end

    it "does not serve a path that has a NUL byte" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, except: ["/templates"])
        _, body, reached, _ = serve.call(handler, "GET", "/templates%00/a/b.jinja")

        body.should_not contain("SECRET")
        reached.should be_false
      end
    end

    it "does not serve a HEAD request, nor redirect a directory" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, except: ["/templates"])

        ["/templates/a/b.jinja", "/templates/sub", "/templates"].each do |path|
          status, _, reached, location = serve.call(handler, "HEAD", path)
          reached.should be_true
          status.should_not eq(301)
          location.should be_nil
        end
      end
    end

    on_disk.each do |path, secret|
      it "serves #{path} without except and refuses it with except (the specs can fail)" do
        with_temp_dir(files) do |dir|
          _, body, reached, _ = serve.call(Azu::Handler::Static.new(dir), "GET", path)
          body.should eq(secret)
          reached.should be_false

          _, body, reached, _ = serve.call(Azu::Handler::Static.new(dir, except: ["/templates"]), "GET", path)
          body.should eq("NEXT")
          reached.should be_true
        end
      end
    end

    ["", "/", ".", "..", "/x/..", "./", " ", "...", "\\", "/./."].each do |entry|
      it "rejects the entry #{entry.inspect}, which would exclude every path" do
        expect_raises(ArgumentError, /would exclude every path/) do
          Azu::Handler::Static.new("public", except: [entry])
        end
      end
    end

    it "refuses a single file given with a trailing slash" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, except: ["/app.css/"])
        serve.call(handler, "GET", "/app.css")[1].should eq("NEXT")
      end
    end

    it "answers 405 for a POST under an excluded path with fallthrough: false" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: false, except: ["/templates"])
        serve.call(handler, "POST", "/templates/a/b.jinja")[0].should eq(405)
      end
    end

    it "does not raise on invalid UTF-8 after percent-decoding" do
      with_temp_dir(files) do |dir|
        [true, false].each do |fallthrough|
          handler = Azu::Handler::Static.new(dir, fallthrough: fallthrough, except: ["/templates"])
          ["/%ff", "/templates/%ff", "/%ff/templates/note.txt"].each do |path|
            status, body, _, _ = serve.call(handler, "GET", path)
            body.should_not contain("SECRET")
            [200, 302, 400, 404].should contain(status)
          end
        end
      end
    end

    it "refuses an excluded directory when directory_listing is on" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, directory_listing: true, except: ["/templates"])
        serve.call(handler, "GET", "/templates/")[1].should eq("NEXT")
        serve.call(handler, "GET", "/templates/a/")[1].should eq("NEXT")
      end
    end

    # Known limit: the listing of the parent still names the excluded entry (the names, never the content).
    pending "hides the excluded name from the listing of its parent"

    # Known limit: the check is lexical. A symlink inside public/ that points into an excluded directory is a
    # different path, so it is served; do not symlink into an excluded directory.
    pending "refuses a symlink that points into an excluded directory"

    it "answers 404 itself with fallthrough: false, for GET, HEAD and a directory" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, fallthrough: false, except: ["/templates"])

        [{"GET", "/templates/a/b.jinja"}, {"HEAD", "/templates/a/b.jinja"}, {"GET", "/templates/sub"},
         {"GET", "/%74emplates/sub/"}].each do |(method, path)|
          status, body, reached, location = serve.call(handler, method, path)
          status.should eq(404)
          body.should_not contain("SECRET")
          reached.should be_false
          location.should be_nil
        end
      end
    end

    it "keeps serving files outside the excluded directory" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, except: ["/templates"])

        {"/app.css" => "PUBLIC-CSS", "/templates-x/a.txt" => "PUBLIC-X", "/templates.txt" => "PUBLIC-DOT",
         "/other/templates/shared.txt" => "PUBLIC-NESTED", "/" => "PUBLIC-HOME"}.each do |path, content|
          _, body, reached, _ = serve.call(handler, "GET", path)
          body.should eq(content)
          reached.should be_false
        end
      end
    end

    it "normalises the entries: leading slash added, trailing slash, case and backslashes ignored" do
      ["templates", "/templates/", "templates/", "/TEMPLATES", "\\templates", "/templates./", "/x/../templates"].each do |entry|
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir, except: [entry])
          _, body, reached, _ = serve.call(handler, "GET", "/templates/a/b.jinja")

          body.should eq("NEXT")
          reached.should be_true
        end
      end
    end

    it "excludes several entries and nested ones, but only below the entry" do
      with_temp_dir(files) do |dir|
        handler = Azu::Handler::Static.new(dir, except: ["/templates/a", "/app.css"])

        serve.call(handler, "GET", "/templates/a/b.jinja")[1].should eq("NEXT")
        serve.call(handler, "GET", "/app.css")[1].should eq("NEXT")
        serve.call(handler, "GET", "/templates/note.txt")[1].should eq("SECRET-NOTE")
        serve.call(handler, "GET", "/templates/ab")[1].should eq("NEXT")
        serve.call(handler, "GET", "/app.css.map")[2].should be_true
      end
    end
  end

  describe "file types" do
    files = {
      "templates/layout.jinja"                           => "SECRET-JINJA",
      "templates/x.JINJA"                                => "SECRET-UPPER",
      "templates/y.ecr"                                  => "SECRET-ECR",
      "templates/z.j2"                                   => "SECRET-J2",
      "app.cr"                                           => "SECRET-CR",
      ".env"                                             => "SECRET-ENV",
      "config.yml"                                       => "SECRET-YML",
      "dump.sql"                                         => "SECRET-SQL",
      "data.db"                                          => "SECRET-DB",
      "data.sqlite"                                      => "SECRET-SQLITE",
      "README.md"                                        => "DOC-MD",
      "server.pem"                                       => "SECRET-PEM",
      "id.key"                                           => "SECRET-KEY",
      "backup.bak"                                       => "SECRET-BAK",
      "run.sh"                                           => "SECRET-SH",
      "tool.py"                                          => "SECRET-PY",
      "app.rb"                                           => "SECRET-RB",
      "setup.exe"                                        => "SECRET-EXE",
      "notes.markdown"                                   => "SECRET-MARKDOWN",
      ".well-known/.git/config"                          => "SECRET-GIT",
      ".well-known/.d/token"                             => "SECRET-DOTDIR",
      ".well-known/a/b/c"                                => "SECRET-DEEP",
      ".well-known/.secrets.json"                        => "SECRET-DOTJSON",
      ".well-known/token."                               => "SECRET-TRAILING-DOT",
      ".Well-Known/.secrets.json"                        => "SECRET-CASE-DOTJSON",
      ".Well-Known/a/b/c.json"                           => "SECRET-CASE-DEEP",
      ".well-known/openid-configuration"                 => "{}",
      "LICENSE"                                          => "SECRET-EXTENSIONLESS",
      "page.jinja.html"                                  => "<p>HTML</p>",
      "page.html.jinja"                                  => "SECRET-HTML-JINJA",
      "app.css"                                          => "PUBLIC-CSS",
      "A.PNG"                                            => "PNGBYTES",
      ".well-known/acme-challenge/Xy_z-0123456789abcdef" => "token.thumbprint",
      ".well-known/security.txt"                         => "Contact: mailto:security@example.com",
      ".well-known/.env"                                 => "SECRET-WELLKNOWN-ENV",
      ".well-known/private-key"                          => "KEY",
      ".well-known/notes.md"                             => "SECRET-WELLKNOWN-MD",
      "other/.well-known/token"                          => "NOT-ROOT-WELLKNOWN",
      "listing/known.txt"                                => "KNOWN",
      "listing/unknown.jinja"                            => "SECRET-LISTED",
    }

    # The status, the body, whether the next handler (the router) was reached, and the response headers.
    serve = ->(handler : Azu::Handler::Static, method : String, path : String, headers : HTTP::Headers) do
      reached = false
      handler.next = ->(ctx : HTTP::Server::Context) { reached = true; ctx.response.print "NEXT" }
      context, io = create_context(method, path, headers)
      handler.call(context)
      body = get_response_body(context, io)
      {context.response.status_code, body, reached, context.response.headers}
    end
    get = ->(handler : Azu::Handler::Static, path : String) { serve.call(handler, "GET", path, HTTP::Headers.new) }

    refused = [
      "/templates/layout.jinja", "/templates/x.JINJA", "/templates/x.jinja", "/templates/y.ecr", "/templates/z.j2",
      "/app.cr", "/.env", "/config.yml", "/dump.sql", "/data.db", "/data.sqlite", "/README.md",
      "/LICENSE", "/page.html.jinja", "/templates/layout.jinja.", "/templates/layout.jinja%20",
      "/.well-known/.env", "/.well-known/notes.md", "/other/.well-known/token",
      "/server.pem", "/id.key", "/backup.bak", "/run.sh", "/tool.py", "/app.rb", "/setup.exe", "/notes.markdown",
      "/.well-known/.git/config", "/.well-known/.d/token", "/.well-known/a/b/c", "/.well-known/.secrets.json",
      "/.well-known/token.",
    ]

    describe "an unknown type" do
      refused.each do |path|
        it "falls through for #{path}" do
          with_temp_dir(files) do |dir|
            status, body, reached, headers = get.call(Azu::Handler::Static.new(dir), path)

            body.should eq("NEXT")
            reached.should be_true
            status.should eq(200)
            headers["Content-Type"]?.should be_nil
          end
        end

        it "answers 404 for #{path} without fallthrough" do
          with_temp_dir(files) do |dir|
            status, body, reached, headers = get.call(Azu::Handler::Static.new(dir, fallthrough: false), path)

            status.should eq(404)
            body.should_not contain("SECRET")
            body.should_not contain("DOC-MD")
            reached.should be_false
            headers["Content-Type"]?.should be_nil
          end
        end
      end

      it "does not raise for an extension nothing registered (it was a KeyError and a 500)" do
        with_temp_dir({"x.zzqq" => "BYTES"}) do |dir|
          status, body, reached, _ = get.call(Azu::Handler::Static.new(dir), "/x.zzqq")

          body.should eq("NEXT")
          reached.should be_true
          status.should eq(200)
        end
      end

      it "answers a HEAD request as the path was not a file" do
        with_temp_dir(files) do |dir|
          status, body, reached, headers = serve.call(Azu::Handler::Static.new(dir), "HEAD", "/templates/layout.jinja", HTTP::Headers.new)

          reached.should be_true
          body.should eq("NEXT")
          headers["ETag"]?.should be_nil
        end
      end

      it "answers a HEAD request 404 without fallthrough" do
        with_temp_dir(files) do |dir|
          status, body, _, headers = serve.call(Azu::Handler::Static.new(dir, fallthrough: false), "HEAD", "/templates/layout.jinja", HTTP::Headers.new)

          status.should eq(404)
          body.should eq("")
          headers["ETag"]?.should be_nil
        end
      end

      it "does not honour a Range request" do
        with_temp_dir(files) do |dir|
          [true, false].each do |fallthrough|
            status, body, _, headers = serve.call(Azu::Handler::Static.new(dir, fallthrough: fallthrough), "GET", "/templates/layout.jinja", HTTP::Headers{"Range" => "bytes=0-5"})

            status.should_not eq(206)
            body.should_not contain("SECRET")
            headers["Content-Range"]?.should be_nil
          end
        end
      end

      it "is not answered 304 for a matching ETag" do
        with_temp_dir(files) do |dir|
          status, body, reached, _ = serve.call(Azu::Handler::Static.new(dir), "GET", "/templates/layout.jinja", HTTP::Headers{"If-None-Match" => "*"})

          status.should_not eq(304)
          reached.should be_true
        end
      end

      it "is not listed as served: a directory listing does not serve the file it lists" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir, directory_listing: true)

          get.call(handler, "/listing/known.txt")[1].should eq("KNOWN")
          status, body, reached, _ = get.call(handler, "/listing/unknown.jinja")
          body.should eq("NEXT")
          reached.should be_true
        end
      end

      it "is refused after the except check: an excluded unknown file falls through the same way" do
        with_temp_dir(files) do |dir|
          [true, false].each do |fallthrough|
            handler = Azu::Handler::Static.new(dir, fallthrough: fallthrough, except: ["/templates"])
            status, body, reached, _ = get.call(handler, "/templates/layout.jinja")

            body.should_not contain("SECRET")
            reached.should eq(fallthrough)
            status.should eq(fallthrough ? 200 : 404)
          end
        end
      end

      it "leaves an excluded known type refused as before" do
        with_temp_dir({"templates/a.txt" => "SECRET-TXT"}) do |dir|
          handler = Azu::Handler::Static.new(dir, except: ["/templates"])
          get.call(handler, "/templates/a.txt")[1].should eq("NEXT")
        end
      end
    end

    describe "a template under public/templates" do
      # The scaffold keeps Jinja templates in public/templates. A page body never leaves the server, whether or
      # not the application excludes the directory: without `except` the type is unknown and refused.
      ["/templates/layout.jinja", "/templates/x.JINJA", "/templates/y.ecr", "/templates/z.j2"].each do |path|
        [true, false].each do |fallthrough|
          [[] of String, ["/templates"]].each do |except|
            it "never returns the body of #{path} (fallthrough #{fallthrough}, except #{except})" do
              with_temp_dir(files) do |dir|
                handler = Azu::Handler::Static.new(dir, fallthrough: fallthrough, except: except)
                status, body, reached, headers = get.call(handler, path)

                body.should_not contain("SECRET")
                status.should_not eq(500)
                headers["Content-Type"]?.should be_nil
                reached.should eq(fallthrough)
              end
            end
          end
        end
      end
    end

    describe "a known type" do
      {
        "/app.css"         => "text/css; charset=utf-8",
        "/A.PNG"           => "image/png",
        "/page.jinja.html" => "text/html; charset=utf-8",
      }.each do |path, type|
        it "serves #{path} as #{type} with nosniff" do
          with_temp_dir(files) do |dir|
            status, _, reached, headers = get.call(Azu::Handler::Static.new(dir), path)

            status.should eq(200)
            reached.should be_false
            headers["Content-Type"].should eq(type)
            headers["X-Content-Type-Options"].should eq("nosniff")
          end
        end
      end

      it "types a double extension by its last one: page.jinja.html is HTML, page.html.jinja is refused" do
        with_temp_dir(files) do |dir|
          get.call(Azu::Handler::Static.new(dir), "/page.jinja.html")[1].should eq("<p>HTML</p>")
          get.call(Azu::Handler::Static.new(dir), "/page.html.jinja")[1].should eq("NEXT")
        end
      end

      it "serves a HEAD request without a body, with the type" do
        with_temp_dir(files) do |dir|
          status, body, reached, headers = serve.call(Azu::Handler::Static.new(dir), "HEAD", "/app.css", HTTP::Headers.new)

          status.should eq(200)
          reached.should be_false
          headers["Content-Type"].should eq("text/css; charset=utf-8")
        end
      end

      it "serves a Range request of a known type" do
        with_temp_dir(files) do |dir|
          status, body, _, headers = serve.call(Azu::Handler::Static.new(dir), "GET", "/app.css", HTTP::Headers{"Range" => "bytes=0-5"})

          status.should eq(206)
          body.should eq("PUBLIC")
          headers["Content-Type"].should eq("text/css; charset=utf-8")
        end
      end
    end

    # What the handler adds to Crystal's own table, so assets a web application serves keep working.
    registered = {
      ".ico"         => "image/vnd.microsoft.icon",
      ".webmanifest" => "application/manifest+json",
      ".avif"        => "image/avif",
      ".mp4"         => "video/mp4",
      ".webm"        => "video/webm",
      ".mp3"         => "audio/mpeg",
      ".ogg"         => "audio/ogg",
      ".wav"         => "audio/wav",
      ".m4a"         => "audio/mp4",
      ".csv"         => "text/csv; charset=utf-8",
      ".vtt"         => "text/vtt; charset=utf-8",
      ".mjs"         => "text/javascript; charset=utf-8",
      ".eot"         => "application/vnd.ms-fontobject",
      ".rss"         => "application/rss+xml",
      ".atom"        => "application/atom+xml",
      ".zip"         => "application/zip",
      ".gz"          => "application/gzip",
      ".tgz"         => "application/gzip",
      ".tar"         => "application/x-tar",
      ".bz2"         => "application/x-bzip2",
      ".xz"          => "application/x-xz",
      ".7z"          => "application/x-7z-compressed",
      ".jsonld"      => "application/ld+json",
      ".xhtml"       => "application/xhtml+xml",
      ".ics"         => "text/calendar; charset=utf-8",
      ".bmp"         => "image/bmp",
      ".tif"         => "image/tiff",
      ".tiff"        => "image/tiff",
      ".woff"        => "font/woff",
      ".woff2"       => "font/woff2",
      ".ttf"         => "font/ttf",
      ".otf"         => "font/otf",
      ".map"         => "application/json",
      ".xml"         => "text/xml; charset=utf-8",
      ".webp"        => "image/webp",
      ".wasm"        => "application/wasm",
    }

    describe "a registered type" do
      registered.each do |extension, type|
        it "serves #{extension} as #{type} with nosniff, in either case" do
          ["file#{extension}", "FILE#{extension.upcase}"].each do |name|
            with_temp_dir({name => "BYTES"}) do |dir|
              status, body, reached, headers = get.call(Azu::Handler::Static.new(dir), "/#{name}")

              body.should eq("BYTES")
              status.should eq(200)
              reached.should be_false
              headers["Content-Type"].should eq(type)
              headers["X-Content-Type-Options"].should eq("nosniff")
            end
          end
        end
      end

      # The table is the handler's own: it never asks the operating system (/etc/mime.types would add .sql, .yml,
      # .md, .pem, .key, .sh, .py, .rb, .bak ... on some hosts), so these are refused on every host.
      %w(.jinja .j2 .cr .ecr .yml .yaml .env .sql .db .sqlite .sqlite3 .md .markdown .pem .key .crt .asc .bak .sh .py .rb .exe .dmg .apk .bin .svgz).each do |extension|
        it "does not have #{extension}" do
          Azu::Handler::Static::MIME_TYPES.has_key?(extension).should be_false
        end
      end

      it "does not consult the operating system" do
        Azu::Handler::Static::MIME_TYPES.keys.each { |extension| extension.should match(/\A\.[a-z0-9]+\z/) }
        Azu::Handler::Static::MIME_TYPES[".sql"]?.should be_nil
        Azu::Handler::Static::MIME_TYPES[".js"].should eq("text/javascript")
      end

      it "has every one of Crystal's built-in defaults with its type (Azu's .js has no charset), and nothing the OS adds" do
        MIME::DEFAULT_TYPES.each do |extension, type|
          expected = extension == ".js" ? "text/javascript" : type
          Azu::Handler::Static::MIME_TYPES[extension]?.should eq(expected)
        end
      end
    end

    describe "an extensionless file" do
      it "serves a file of /.well-known/ as text/plain (ACME HTTP-01 tokens, no extension)" do
        with_temp_dir(files) do |dir|
          status, body, reached, headers = get.call(Azu::Handler::Static.new(dir), "/.well-known/acme-challenge/Xy_z-0123456789abcdef")

          status.should eq(200)
          body.should eq("token.thumbprint")
          reached.should be_false
          headers["Content-Type"].should eq("text/plain; charset=utf-8")
          headers["X-Content-Type-Options"].should eq("nosniff")
        end
      end

      it "serves /.well-known/security.txt as text/plain" do
        with_temp_dir(files) do |dir|
          _, body, _, headers = get.call(Azu::Handler::Static.new(dir), "/.well-known/security.txt")

          body.should eq("Contact: mailto:security@example.com")
          headers["Content-Type"].should eq("text/plain; charset=utf-8")
        end
      end

      it "serves any extensionless file directly below /.well-known/, and redirects a dot segment to it" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          get.call(handler, "/.well-known/private-key")[1].should eq("KEY")

          status, _, _, headers = get.call(handler, "/x/../.well-known/private-key")
          status.should eq(302)
          headers["Location"].should eq("/.well-known/private-key")
        end
      end

      it "serves /.well-known/<file> and /.well-known/<dir>/<file> only, with plain names" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          get.call(handler, "/.well-known/acme-challenge/Xy_z-0123456789abcdef")[1].should eq("token.thumbprint")
          get.call(handler, "/.well-known/openid-configuration")[1].should eq("{}")
          ["/.well-known/.git/config", "/.well-known/.d/token", "/.well-known/a/b/c", "/.well-known/.secrets.json", "/.well-known/token."].each do |path|
            body = get.call(handler, path)[1]
            body.should eq("NEXT")
          end
        end
      end

      it "applies the depth and dot rule whatever the case of .well-known" do
        with_temp_dir(files) do |dir|
          handler = Azu::Handler::Static.new(dir)
          ["/.Well-Known/.secrets.json", "/.Well-Known/a/b/c.json"].each do |path|
            get.call(handler, path)[1].should_not contain("SECRET")
          end
        end
      end

      it "refuses an extensionless file anywhere else, and a dotfile of /.well-known/" do
        with_temp_dir(files) do |dir|
          ["/LICENSE", "/other/.well-known/token", "/.well-known/.env"].each do |path|
            get.call(Azu::Handler::Static.new(dir), path)[1].should eq("NEXT")
          end
        end
      end
    end

    describe "mime_types" do
      it "serves an extension the application adds, with the type it gave" do
        with_temp_dir({"report.foo" => "FOOBYTES", "Photo.HEIC" => "HEIC"}) do |dir|
          handler = Azu::Handler::Static.new(dir, mime_types: {".foo" => "text/x-foo", "heic" => "image/heic"})

          _, body, _, headers = get.call(handler, "/report.foo")
          body.should eq("FOOBYTES")
          headers["Content-Type"].should eq("text/x-foo")
          headers["X-Content-Type-Options"].should eq("nosniff")

          get.call(handler, "/Photo.HEIC")[3]["Content-Type"].should eq("image/heic")
        end
      end

      it "normalises the extension: lower case, leading dot" do
        with_temp_dir({"a.foo" => "X"}) do |dir|
          ["FOO", ".FOO", ".foo", "foo"].each do |extension|
            handler = Azu::Handler::Static.new(dir, mime_types: {extension => "text/x-foo"})
            get.call(handler, "/a.foo")[3]["Content-Type"].should eq("text/x-foo")
          end
        end
      end

      it "does not change the table for another handler or for Crystal" do
        with_temp_dir({"a.foo" => "X"}) do |dir|
          Azu::Handler::Static.new(dir, mime_types: {".foo" => "text/x-foo"})

          get.call(Azu::Handler::Static.new(dir), "/a.foo")[1].should eq("NEXT")
          MIME.from_extension?(".foo").should be_nil # the handler registers nothing globally
        end
      end

      it "overrides a type the handler knows" do
        with_temp_dir({"a.csv" => "X"}) do |dir|
          handler = Azu::Handler::Static.new(dir, mime_types: {".csv" => "application/csv"})
          get.call(handler, "/a.csv")[3]["Content-Type"].should eq("application/csv")
        end
      end

      it "still refuses what it does not list" do
        with_temp_dir({"a.foo" => "X", "t.jinja" => "SECRET"}) do |dir|
          handler = Azu::Handler::Static.new(dir, mime_types: {".foo" => "text/x-foo"})
          get.call(handler, "/t.jinja")[1].should eq("NEXT")
        end
      end

      it "rejects two extensions that are the same after normalisation" do
        expect_raises(ArgumentError) do
          Azu::Handler::Static.new("public", mime_types: {".Foo" => "text/x-foo", "foo" => "text/x-bar"})
        end
      end

      ["", ".", "*", ".*", "*.foo", "a/b", ".a.b", " ", ".foo ", "a b"].each do |extension|
        it "rejects the extension #{extension.inspect}" do
          expect_raises(ArgumentError) do
            Azu::Handler::Static.new("public", mime_types: {extension => "text/x-foo"})
          end
        end
      end

      ["", "text", "text/", "/plain", "text/plain\r\nSet-Cookie: a=b", "*/*", "text/*", "text/a b"].each do |type|
        it "rejects the type #{type.inspect}" do
          expect_raises(ArgumentError) do
            Azu::Handler::Static.new("public", mime_types: {".foo" => type})
          end
        end
      end
    end
  end
end
