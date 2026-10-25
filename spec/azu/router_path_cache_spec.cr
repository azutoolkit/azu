require "../spec_helper"

private struct Marker
  include Azu::Routable

  def initialize(@name : String)
  end

  def call(context : HTTP::Server::Context)
    context.response << @name
    context
  end
end

private def serve(router : Azu::Router, method : String, path : String, upgrade : Bool = false) : String
  request = HTTP::Request.new(method, path)
  if upgrade
    request.headers["Upgrade"] = "websocket"
    request.headers["Connection"] = "Upgrade"
  end
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  router.process(HTTP::Server::Context.new(request, response))
  response.close
  io.rewind
  io.gets_to_end.partition("\r\n\r\n")[2]
end

describe Azu::Router do
  describe "path cache" do
    it "keeps the same path of different methods apart" do
      router = Azu::Router.new
      router.get "/thing", Marker.new("got")
      router.post "/thing", Marker.new("posted")

      3.times do
        serve(router, "GET", "/thing").should eq "got"
        serve(router, "POST", "/thing").should eq "posted"
      end
      router.path_cache.stats[:size].should eq 2
    end

    it "keeps a WebSocket upgrade apart from a plain request for the same path" do
      router = Azu::Router.new
      router.get "/chat", Marker.new("page")
      router.add "/chat", Marker.new("socket"), Azu::Method::WebSocket

      3.times do
        serve(router, "GET", "/chat").should eq "page"
        serve(router, "GET", "/chat", upgrade: true).should eq "socket"
      end
      router.path_cache.stats[:size].should eq 2
    end

    it "stops adding at 1000 entries, keeps what it has and still routes every request" do
      router = Azu::Router.new
      router.get "/items/:id", Marker.new("item")

      1100.times { |i| serve(router, "GET", "/items/#{i}").should eq "item" }

      stats = router.path_cache.stats
      stats[:size].should eq 1000
      stats[:max_size].should eq 1000
      stats[:fill_percent].should eq 100.0
      # Neither a repeat of a cached path nor a path past the limit changes the size
      serve(router, "GET", "/items/0").should eq "item"
      serve(router, "GET", "/items/1099").should eq "item"
      router.path_cache.stats[:size].should eq 1000
    end

    it "counts a path once however often it is requested" do
      router = Azu::Router.new
      router.get "/once", Marker.new("once")

      20.times { serve(router, "GET", "/once") }

      router.path_cache.stats[:size].should eq 1
    end

    it "starts empty again after clear_path_cache" do
      router = Azu::Router.new
      router.get "/clear", Marker.new("clear")
      serve(router, "GET", "/clear")
      router.path_cache.stats[:size].should eq 1

      router.clear_path_cache

      router.path_cache.stats[:size].should eq 0
      serve(router, "GET", "/clear").should eq "clear"
      router.path_cache.stats[:size].should eq 1
    end

    it "stays consistent when many fibers fill it at once" do
      router = Azu::Router.new
      router.get "/items/:id", Marker.new("item")
      done = ::Channel(Int32).new(8)

      8.times do |worker|
        spawn do
          wrong = 0
          # Every fiber asks for the same 300 paths, in its own order, so inserts collide
          300.times do |i|
            id = (i * (worker + 1)) % 300
            wrong += 1 unless serve(router, "GET", "/items/#{id}") == "item"
            Fiber.yield if i % 25 == 0
          end
          done.send(wrong)
        end
      end

      8.times { done.receive.should eq 0 }
      router.path_cache.stats[:size].should eq 300
    end
  end
end
