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
end
