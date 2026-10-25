require "../../spec_helper"
require "../../../benchmark/micro/harness"

private alias Tree = Azu::Router::Tree(String)

# A tree holding each route as "<METHOD> <path>", so a find shows which route it reached.
private def tree(*routes : {Azu::Method, String}) : Tree
  tree = Tree.new
  routes.each { |(method, path)| tree.add method, path, "#{method} #{path}" }
  tree
end

private def payload(tree : Tree, method : Azu::Method, path : String) : String?
  tree.find(method, path).try(&.payload)
end

private GET  = Azu::Method::Get
private POST = Azu::Method::Post

describe Azu::Router::Tree do
  describe "static segments" do
    it "finds the payload of the route for its method" do
      routes = tree({GET, "/"}, {GET, "/users"}, {POST, "/users"}, {GET, "/api/v1/users"})

      payload(routes, GET, "/").should eq "Get /"
      payload(routes, GET, "/users").should eq "Get /users"
      payload(routes, POST, "/users").should eq "Post /users"
      payload(routes, GET, "/api/v1/users").should eq "Get /api/v1/users"
      routes.find(GET, "/users").try(&.params).should be_nil
    end

    it "finds nothing for another method or an unknown path" do
      routes = tree({GET, "/users"}, {GET, "/api/v1/users"})

      payload(routes, POST, "/users").should be_nil
      payload(routes, GET, "/").should be_nil
      payload(routes, GET, "/user").should be_nil
      payload(routes, GET, "/usersx").should be_nil
      payload(routes, GET, "/users/1").should be_nil
      payload(routes, GET, "/api/v1").should be_nil
      payload(routes, GET, "users").should be_nil
    end

    it "matches a path of more segments than the stack holds" do
      long = "/s" * 40
      routes = tree({GET, long})

      payload(routes, GET, long).should eq "Get #{long}"
      payload(routes, GET, long + "/s").should be_nil
    end

    it "allocates nothing to find a static route among 100 siblings" do
      routes = Tree.new
      100.times { |i| routes.add GET, "/api/v1/resource#{i}", "resource#{i}" }
      payload(routes, GET, "/api/v1/resource57").should eq "resource57"

      HotPath.bytes_per_call { routes.find(GET, "/api/v1/resource57") }.should eq 0
    end
  end

  describe "named segments" do
    it "captures each parameter raw, without percent-decoding it, as radix does" do
      routes = tree({GET, "/users/:id"}, {GET, "/users/:id/posts/:post_id"})

      routes.find(GET, "/users/a%20b").try(&.params).should eq({"id" => "a%20b"})
      routes.find(GET, "/users/7/posts/9").try(&.params).should eq({"id" => "7", "post_id" => "9"})
      payload(routes, GET, "/users/7/posts").should be_nil
    end

    it "prefers a static segment to a parameter" do
      routes = tree({GET, "/users/:id"}, {GET, "/users/new"})

      payload(routes, GET, "/users/new").should eq "Get /users/new"
      routes.find(GET, "/users/new").try(&.params).should be_nil
      payload(routes, GET, "/users/newer").should eq "Get /users/:id"
    end

    it "backtracks to the parameter when the static branch dead-ends" do
      routes = tree({GET, "/a/b/c"}, {GET, "/a/:x/d"})
      found = routes.find(GET, "/a/b/d")

      found.try(&.payload).should eq "Get /a/:x/d"
      found.try(&.params).should eq({"x" => "b"})
      payload(routes, GET, "/a/b/c").should eq "Get /a/b/c"
    end

    it "keeps the parameter names of each method's route" do
      routes = tree({GET, "/posts/:id"}, {POST, "/posts/:post_id/comments"})

      routes.find(GET, "/posts/1").try(&.params).should eq({"id" => "1"})
      routes.find(POST, "/posts/1/comments").try(&.params).should eq({"post_id" => "1"})
    end

    it "interns the parameter names and allocates only the values and the params hash" do
      routes = Tree.new
      100.times { |i| routes.add GET, "/api/v1/resource#{i}/:id", "resource#{i}" }
      names = {"/api/v1/resource1/1", "/api/v1/resource2/2"}.map { |path| routes.find(GET, path).try(&.params).try(&.keys.first) }

      names.first.should_not be_nil
      names.first.should be names.last
      value = "123".to_slice
      by_hand = HotPath.bytes_per_call { Hash(String, String).new(initial_capacity: 1)["id"] = String.new(value) }
      # Within less than the smallest heap object (16 B): GC statistics add a byte or two of noise per call
      HotPath.bytes_per_call { routes.find(GET, "/api/v1/resource57/123") }.should be_close(by_hand, 8)
    end
  end

  describe "glob segments" do
    it "captures the rest of the path, slashes included, after named and static routes" do
      routes = tree({GET, "/files/*path"}, {GET, "/files/:id/meta"}, {GET, "/files/:id/*tail"})

      routes.find(GET, "/files/a/b/c.txt").try(&.params).should eq({"id" => "a", "tail" => "b/c.txt"})
      routes.find(GET, "/files/a/meta").try(&.params).should eq({"id" => "a"})
      routes.find(GET, "/files/a").try(&.params).should eq({"id" => "a", "tail" => ""})
      payload(routes, POST, "/files/a/b").should be_nil
    end

    it "captures an empty value when nothing follows the glob" do
      routes = tree({GET, "/files/*path"})

      routes.find(GET, "/files").try(&.params).should eq({"path" => ""})
      routes.find(GET, "/files/x").try(&.params).should eq({"path" => "x"})
      payload(routes, GET, "/filesx").should be_nil
    end

    it "matches a path of 40 segments" do
      rest = (2..40).join('/')
      routes = tree({GET, "/deep/*rest"})

      routes.find(GET, "/deep/#{rest}").try(&.params).should eq({"rest" => rest})
    end

    it "refuses a glob before the last segment" do
      expect_raises(Tree::Error, "/a/*rest/b: a glob must be the last segment") { tree({GET, "/a/*rest/b"}) }
    end
  end
end
