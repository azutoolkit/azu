require "../spec_helper"

# Concrete implementation for testing WebSocket channels
class TestChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

class ExampleEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  def call : Azu::Response
    Azu::Response::Empty.new
  end
end

class TestEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  def call : Azu::Response
    Azu::Response::Empty.new
  end
end

struct TestResponse
  include Azu::Response

  def render
    "Hello, World!"
  end
end

class SimpleEndpoint
  include Azu::Endpoint(Azu::Request, TestResponse)

  def call : TestResponse
    TestResponse.new
  end
end

private class PlainHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    context.response << "plain"
  end
end

private struct RoutableStruct
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "routable"
  end
end

private struct ParamsHandler
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << context.request.path_params
  end
end

private def dispatch(router : Azu::Router, path : String) : String
  io = IO::Memory.new
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))
  router.process(context)
  context.response.flush
  io.to_s
end

describe Azu::Router do
  describe "routable targets" do
    it "dispatches to an HTTP::Handler class, a struct that is only Routable and the root" do
      router = Azu::Router.new
      router.get "/plain", PlainHandler.new
      router.add "/struct", RoutableStruct.new, Azu::Method::Get
      router.root RoutableStruct.new

      dispatch(router, "/plain").should contain "plain"
      dispatch(router, "/struct").should contain "routable"
      dispatch(router, "/").should contain "routable"
    end
  end

  describe "route registration" do
    it "adds GET endpoint" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds POST endpoint" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/submit", endpoint, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds multiple endpoints" do
      router = Azu::Router.new
      endpoint1 = ExampleEndpoint.new
      endpoint2 = TestEndpoint.new

      router.add "/", endpoint1, Azu::Method::Get
      router.add "/api", endpoint2, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds endpoints with different HTTP methods" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users", endpoint, Azu::Method::Get
      router.add "/users", endpoint, Azu::Method::Post
      router.add "/users", endpoint, Azu::Method::Put
      router.add "/users", endpoint, Azu::Method::Delete

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "route matching" do
    it "matches exact paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/test", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "matches paths with parameters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/users/:id", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "matches nested paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/api/v1/users", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "WebSocket routes" do
    it "adds WebSocket routes" do
      router = Azu::Router.new

      router.ws "/ws", TestChannel

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "router configuration" do
    it "creates router instance" do
      router = Azu::Router.new
      router.should be_a(Azu::Router)
    end

    it "handles empty router" do
      router = Azu::Router.new
      router.should be_a(Azu::Router)
    end
  end

  describe "route conflicts" do
    it "handles duplicate routes gracefully" do
      router = Azu::Router.new
      endpoint1 = ExampleEndpoint.new
      endpoint2 = TestEndpoint.new

      router.add "/duplicate", endpoint1, Azu::Method::Get

      expect_raises(Azu::Router::DuplicateRoute, "http_method: Get, path: /duplicate, endpoint:") do
        router.add "/duplicate", endpoint2, Azu::Method::Get
      end
    end

    it "refuses a get \"/\" next to a root, in either order" do
      rooted = Azu::Router.new
      rooted.root RoutableStruct.new
      expect_raises(Azu::Router::DuplicateRoute, "http_method: Get, path: /,") { rooted.get "/", RoutableStruct.new }

      declared = Azu::Router.new
      declared.get "/", RoutableStruct.new
      expect_raises(Azu::Router::DuplicateRoute, "http_method: Get, path: /,") { declared.root RoutableStruct.new }
    end
  end

  describe "complex routing scenarios" do
    it "handles RESTful routes" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users", endpoint, Azu::Method::Get
      router.add "/users/:id", endpoint, Azu::Method::Get
      router.add "/users", endpoint, Azu::Method::Post
      router.add "/users/:id", endpoint, Azu::Method::Put
      router.add "/users/:id", endpoint, Azu::Method::Delete

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles nested resource routes" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users/:user_id/posts", endpoint, Azu::Method::Get
      router.add "/users/:user_id/posts/:post_id", endpoint, Azu::Method::Get
      router.add "/users/:user_id/posts", endpoint, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "dispatches nested resources of one method, each route with its own parameter names" do
      router = Azu::Router.new
      router.get "/posts/:id", ParamsHandler.new
      router.get "/posts/:post_id/comments", ParamsHandler.new

      dispatch(router, "/posts/1").should contain %({"id" => "1"})
      dispatch(router, "/posts/1/comments").should contain %({"post_id" => "1"})
    end

    it "handles optional parameters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/search", endpoint, Azu::Method::Get
      router.add "/search/:query", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "edge cases" do
    it "handles root path" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles paths with special characters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/api/v1/users", endpoint, Azu::Method::Get
      router.add "/api/v1/users/:id", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles very long paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      long_path = "/" + "a" * 1000

      router.add long_path, endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "performance" do
    it "handles many routes efficiently" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      # Add many routes
      100.times do |i|
        router.add "/route#{i}", endpoint, Azu::Method::Get
      end

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "request processing" do
    it "answers a repeated request the same way" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/hello", endpoint)

      # Create a mock context
      request = HTTP::Request.new("GET", "/hello")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close

      io.rewind
      first_response = io.gets_to_end
      first_response.should contain("Hello, World!")

      io2 = IO::Memory.new
      response2 = HTTP::Server::Response.new(io2)
      context2 = HTTP::Server::Context.new(HTTP::Request.new("GET", "/hello"), response2)

      router.process(context2)
      response2.close
      io2.rewind
      second_response = io2.gets_to_end
      second_response.should contain("Hello, World!")
    end

    it "handles WebSocket upgrade paths correctly" do
      router = Azu::Router.new

      # Register a WebSocket route for testing
      router.ws("/ws-test", TestChannel)

      # Mock WebSocket request
      request = HTTP::Request.new("GET", "/ws-test")
      request.headers["Upgrade"] = "websocket"
      request.headers["Connection"] = "Upgrade"

      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      # Should handle WebSocket path building without errors
      result = router.process(context)
      # WebSocket routes may return nil or empty string depending on implementation
      (result.nil? || result == "").should be_true
    end

    it "routes each verb it was given a route for" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Test various HTTP methods
      %w(GET POST PUT PATCH DELETE).each do |method|
        router.add("/test-#{method.downcase}", endpoint, Azu::Method.parse(method.downcase))

        request = HTTP::Request.new(method, "/test-#{method.downcase}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end
    end

    it "keeps the same path of different methods, and of a WebSocket upgrade, apart" do
      router = Azu::Router.new
      router.get "/thing", VerbEndpoint.new("get")
      router.post "/thing", VerbEndpoint.new("post")
      router.add "/thing", RoutableStruct.new, Azu::Method::WebSocket
      answer = ->(method : String, upgrade : Bool) do
        request = HTTP::Request.new(method, "/thing")
        request.headers.merge!({"Upgrade" => "websocket", "Connection" => "Upgrade"}) if upgrade
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        router.process(HTTP::Server::Context.new(request, response))
        response.close
        io.to_s
      end

      answer.call("GET", false).should contain "handled by get"
      answer.call("POST", false).should contain "handled by post"
      answer.call("GET", true).should contain "routable"
    end

    it "returns an empty string for a routed request, not a rendering of the context" do
      router = Azu::Router.new
      router.get("/test", SimpleEndpoint.new)
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/test"), HTTP::Server::Response.new(IO::Memory.new))

      router.process(context).should eq ""
    end

    it "handles path normalization correctly" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/test", endpoint)

      # Test path with trailing slash
      request = HTTP::Request.new("GET", "/test/")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "keeps routing after clear_path_cache, which does nothing" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/cached-test", endpoint)

      request = HTTP::Request.new("GET", "/cached-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)

      router.clear_path_cache

      io2 = IO::Memory.new
      response2 = HTTP::Server::Response.new(io2)
      context2 = HTTP::Server::Context.new(HTTP::Request.new("GET", "/cached-test"), response2)

      router.process(context2)
      response2.close
      io2.rewind
      result = io2.gets_to_end
      result.should contain("Hello, World!")
    end

    it "answers 100 requests quickly" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add many routes
      (1..100).each do |i|
        router.get("/test#{i}", endpoint)
      end

      # Make many requests to test performance
      start_time = Time.instant
      (1..100).each do |i|
        request = HTTP::Request.new("GET", "/test#{i}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end
      end_time = Time.instant

      # Performance check: should complete quickly (under 200ms for 100 requests)
      elapsed_time = end_time - start_time
      elapsed_time.total_milliseconds.should be < 200
    end

    it "answers concurrent requests for the same paths" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes
      (1..10).each do |i|
        router.get("/concurrent#{i}", endpoint)
      end

      # Create multiple fibers to simulate concurrent access
      results = [] of String
      results_mutex = Mutex.new
      completed_fibers = 0
      completion_mutex = Mutex.new

      # Spawn 20 concurrent fibers making requests
      20.times do |_|
        spawn do
          (1..10).each do |i|
            request = HTTP::Request.new("GET", "/concurrent#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
            io.rewind
            response_body = io.gets_to_end

            results_mutex.synchronize do
              results << response_body
            end
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 20 }
        sleep(0.001.seconds)
      end

      # Verify all requests completed successfully
      results.size.should eq(200) # 20 fibers * 10 requests each
      results.all?(&.includes?("Hello, World!")).should be_true
    end

    it "answers concurrent requests for distinct paths" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes for all possible requests
      (0...10).each do |fiber_id|
        (1..5).each do |i|
          router.get("/concurrent_write#{fiber_id}_#{i}", endpoint)
        end
      end

      # Create multiple fibers requesting distinct paths simultaneously
      results = [] of String
      results_mutex = Mutex.new
      completed_fibers = 0
      completion_mutex = Mutex.new

      # Spawn 10 concurrent fibers making different requests
      10.times do |fiber_id|
        spawn do
          (1..5).each do |i|
            request = HTTP::Request.new("GET", "/concurrent_write#{fiber_id}_#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
            io.rewind
            response_body = io.gets_to_end

            results_mutex.synchronize do
              results << response_body
            end
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 10 }
        sleep(0.001.seconds)
      end

      # Verify all requests completed successfully
      results.size.should eq(50) # 10 fibers * 5 requests each
      results.all?(&.includes?("Hello, World!")).should be_true
    end

    it "answers 1000 concurrent requests quickly" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes
      (1..20).each do |i|
        router.get("/perf#{i}", endpoint)
      end

      # Create concurrent load
      completed_fibers = 0
      completion_mutex = Mutex.new
      start_time = Time.instant

      # Spawn 50 concurrent fibers
      50.times do |_|
        spawn do
          (1..20).each do |i|
            request = HTTP::Request.new("GET", "/perf#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 50 }
        sleep(0.001.seconds)
      end
      end_time = Time.instant

      # Performance check: should complete quickly (under 500ms for 1000 concurrent requests)
      elapsed_time = end_time - start_time
      elapsed_time.total_milliseconds.should be < 500
    end
  end

  describe "original functionality" do
    it "handles GET requests" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/hello", endpoint)

      request = HTTP::Request.new("GET", "/hello")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles POST requests" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.post("/data", endpoint)

      request = HTTP::Request.new("POST", "/data")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles method override" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.put("/update", endpoint)

      request = HTTP::Request.new("POST", "/update?_method=PUT")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles unknown routes gracefully" do
      router = Azu::Router.new

      request = HTTP::Request.new("GET", "/unknown")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      # Should not raise exception, returns nil for 404s
      result = router.process(context)
      result.should be_nil

      # Check that the response status is set to 404
      response.status_code.should eq(404)
    end
  end

  describe "method override" do
    router = Azu::Router.new
    {% for verb in %w(get post put patch delete) %}
      router.{{verb.id}}("/posts/:id", VerbEndpoint.new("{{verb.id}}"))
    {% end %}

    # Dispatches the request and returns what the handling endpoint rendered
    dispatch = ->(request : HTTP::Request) do
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      router.process(HTTP::Server::Context.new(request, response))
      response.close
      io.rewind
      io.gets_to_end
    end

    form = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

    it "never lets a GET change its method" do
      dispatch.call(HTTP::Request.new("GET", "/posts/1?_method=delete")).should contain("handled by get")
    end

    it "only overrides a POST" do
      dispatch.call(HTTP::Request.new("PUT", "/posts/1?_method=delete")).should contain("handled by put")
    end

    it "reads the _method form field and leaves the body for the endpoint" do
      request = HTTP::Request.new("POST", "/posts/1", form, "_method=delete&title=hello")

      dispatch.call(request).should contain("handled by delete (title=hello)")
    end

    it "accepts the lowercase verbs the form helpers emit" do
      dispatch.call(HTTP::Request.new("POST", "/posts/1", form, "_method=patch")).should contain("handled by patch")
    end

    it "reads the X-HTTP-Method-Override header" do
      headers = HTTP::Headers{"X-HTTP-Method-Override" => "PUT"}

      dispatch.call(HTTP::Request.new("POST", "/posts/1", headers)).should contain("handled by put")
    end

    it "keeps reading _method from the query string of a POST" do
      dispatch.call(HTTP::Request.new("POST", "/posts/1?_method=put")).should contain("handled by put")
    end

    {% for verb in %w(get head options connect trace bogus) %}
      it "ignores the unsupported override {{verb.id}}" do
        dispatch.call(HTTP::Request.new("POST", "/posts/1?_method={{verb.id}}")).should contain("handled by post")
      end
    {% end %}

    it "does not read _method from a JSON body" do
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      dispatch.call(HTTP::Request.new("POST", "/posts/1", headers, %({"_method":"delete"}))).should contain("handled by post")
    end

    describe "behind the CSRF handler, which also reads the form body" do
      post = ->(token : String?) do
        Azu::Handler::CSRF.secret_key = "router_spec_secret_key_for_testing_only"
        Azu::Handler::CSRF.use_signed_double_submit!
        csrf = Azu::Handler::CSRF.new
        csrf.next = ->(context : HTTP::Server::Context) { router.process(context); nil }
        issuer = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))
        issued = Azu::Handler::CSRF.token(issuer)

        body = "_method=delete&title=hello"
        body += "&_csrf=#{URI.encode_www_form(issued)}" if token == "valid"
        headers = form.dup
        headers["Cookie"] = "csrf_token=#{issued}"

        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        csrf.call(HTTP::Server::Context.new(HTTP::Request.new("POST", "/posts/1", headers, body), response))
        response.close
        io.rewind
        io.gets_to_end
      end

      it "overrides the method once the token is valid and the endpoint still reads the body" do
        post.call("valid").should contain("handled by delete (title=hello)")
      end

      it "rejects the request without a token before anything is routed" do
        result = post.call(nil)

        result.should contain("403")
        result.should_not contain("handled by")
      end
    end

    it "refuses an oversized form body while looking for _method" do
      original = Azu::CONFIG.upload.max_file_size
      Azu::CONFIG.upload.max_file_size = 16_u64
      begin
        # No route matches, so only the router itself reads this body
        request = HTTP::Request.new("POST", "/nowhere", form, "title=#{"x" * 100}")

        expect_raises(Azu::Response::PayloadTooLarge) { dispatch.call(request) }
      ensure
        Azu::CONFIG.upload.max_file_size = original
      end
    end
  end

  # The router keys a route by method and path together, so a request reaches a route only when each is exactly
  # what the route was declared with: the route matched is the one `request.path` and `request.method` name (the
  # method as the router sees it, after a POST's `_method` override).
  describe "requests that do not name a route" do
    router = Azu::Router.new
    router.get "/admin/secret", VerbEndpoint.new("get")
    router.get "/secret", VerbEndpoint.new("get")
    router.post "/users", VerbEndpoint.new("post")
    router.ws "/chat", TestChannel

    # Parses the request line (and any header lines after it) as the server does and returns the status and body the router
    # answered with. Newer Crystal versions refuse a method that is not an HTTP token while parsing: such a request never
    # reaches a handler, and counts as a 400 here.
    answer = ->(request_line : String) do
      parsed = begin
        HTTP::Request.from_io(IO::Memory.new("#{request_line}\r\nHost: example.com\r\n\r\n"))
      rescue ArgumentError
        nil
      end
      if request = parsed.as?(HTTP::Request)
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        router.process(HTTP::Server::Context.new(request, response))
        response.close
        {response.status_code, io.to_s}
      else
        {400, ""}
      end
    end

    it "routes the methods and paths as declared" do
      answer.call("GET /admin/secret HTTP/1.1")[1].should contain("handled by get")
      answer.call("POST /users HTTP/1.1")[1].should contain("handled by post")
    end

    it "does not let a slash in the method reach another path" do
      status, body = answer.call("GET/admin /secret HTTP/1.1")
      {400, 404}.should contain(status)
      body.should_not contain("handled by")
    end

    it "does not let a verb split across the method and the path reach a route" do
      status, body = answer.call("PO st/users HTTP/1.1")
      status.should eq 404
      body.should_not contain("handled by")
    end

    it "does not route a path without a leading slash" do
      status, body = answer.call("GET secret HTTP/1.1")
      status.should eq 404
      body.should_not contain("handled by")
    end

    it "refuses a route path without a leading slash when it is declared" do
      expect_raises(ArgumentError, %(route path "secret" must start with /)) { Azu::Router.new.get "secret", VerbEndpoint.new("get") }
    end

    it "does not read a path without a leading slash from its first slash on" do
      {"GET admin/secret HTTP/1.1", "GET x/admin/secret HTTP/1.1"}.each do |request_line|
        status, body = answer.call(request_line)
        status.should eq 404
        body.should_not contain("handled by")
      end
    end

    it "reaches a WebSocket channel only through a GET upgrade" do
      answer.call("POST /chat HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade")[0].should eq 404
    end

    it "reaches a WebSocket channel through a GET upgrade" do
      answer.call("GET /chat HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade")[0].should_not eq 404
    end

    it "takes no method name for the WebSocket slot, with an upgrade or without" do
      {"WEBSOCKET", "web_socket", "websocket"}.each do |method|
        {"", "\r\nUpgrade: websocket\r\nConnection: Upgrade"}.each do |upgrade|
          request = HTTP::Request.from_io(IO::Memory.new("#{method} /chat HTTP/1.1#{upgrade}\r\nHost: example.com\r\n\r\n")).as(HTTP::Request)
          response = HTTP::Server::Response.new(IO::Memory.new)
          router.process(HTTP::Server::Context.new(request, response))

          response.status_code.should eq 404
          # A channel reached without an upgrade answers 404 too: what tells is that the router found no route
          request.headers["X-Azu-Endpoint"]?.should be_nil
        end
      end
    end

    it "treats the method as case-sensitive" do
      answer.call("get /admin/secret HTTP/1.1")[0].should eq 404
    end
  end
end

# Renders the verb it was registered for, plus the title the form body carried
struct VerbResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

class VerbEndpoint
  include Azu::Endpoint(Azu::Request, VerbResponse)

  def initialize(@verb : String)
  end

  def call : VerbResponse
    title = params["title"]?
    VerbResponse.new(title ? "handled by #{@verb} (title=#{title})" : "handled by #{@verb}")
  end
end
