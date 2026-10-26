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

private GET     = Azu::Method::Get
private HEAD    = Azu::Method::Head
private OPTIONS = Azu::Method::Options
private POST    = Azu::Method::Post

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

    it "matches 31 segments on the stack and 32 on the heap, and refuses 33" do
      s31, s32, s33 = "/s" * 31, "/s" * 32, "/s" * 33
      routes = tree({GET, s31}, {GET, s32})

      payload(routes, GET, s31).should eq "Get #{s31}"
      payload(routes, GET, s32).should eq "Get #{s32}"
      payload(routes, GET, s33).should be_nil
      HotPath.bytes_per_call { routes.find(GET, s31) }.should eq 0
    end

    it "allocates nothing to find a static route among 100 siblings" do
      routes = Tree.new
      100.times { |i| routes.add GET, "/api/v1/resource#{i}", "resource#{i}" }
      payload(routes, GET, "/api/v1/resource57").should eq "resource57"

      HotPath.bytes_per_call { routes.find(GET, "/api/v1/resource57") }.should eq 0
    end

    it "allocates nothing to miss a path of more segments than any route, without a glob route" do
      routes = tree({GET, "/users/:id"})
      hostile = "/" * 8000 + "x"

      payload(routes, GET, hostile).should be_nil
      HotPath.bytes_per_call { routes.find(GET, hostile) }.should eq 0
    end

    it "sizes the heap offsets by the deepest route, without a glob route, to miss a longer path" do
      routes = tree({GET, "/s" * 40})
      hostile = "/" * 8000 + "x"

      payload(routes, GET, hostile).should be_nil
      # 42 offsets (168 B), not one per slash of the path (32 KB)
      HotPath.bytes_per_call { routes.find(GET, hostile) }.should be < 256
    end

    it "allocates nothing to miss a path of more segments than any route, with glob routes as a mount adds" do
      routes = tree({GET, "/admin"}, {GET, "/admin/*mount_path"}, {GET, "/users/:id"})
      hostile = "/" * 8000 + "x"

      payload(routes, GET, hostile).should be_nil
      HotPath.bytes_per_call { routes.find(GET, hostile) }.should eq 0
    end

    it "reads a path of more segments than any route only as far as a glob route needs" do
      routes = tree({GET, "/a/:x/:y"}, {GET, "/g/*rest"})

      routes.find(GET, "/a/1/2").try(&.params).should eq({"x" => "1", "y" => "2"})
      payload(routes, GET, "/a/1/2/3").should be_nil
      payload(routes, GET, "/a/1/2/3/4").should be_nil
      routes.find(GET, "/g/1/2/3/4/5").try(&.params).should eq({"rest" => "1/2/3/4/5"})
    end
  end

  describe "named segments" do
    it "captures each parameter raw, without percent-decoding it, as radix does" do
      routes = tree({GET, "/users/:id"}, {GET, "/users/:id/posts/:post_id"})

      routes.find(GET, "/users/a%20b").try(&.params).should eq({"id" => "a%20b"})
      routes.find(GET, "/users/7/posts/9").try(&.params).should eq({"id" => "7", "post_id" => "9"})
      payload(routes, GET, "/users/7/posts").should be_nil
      tree({GET, "/:a/:b/:c/:d/:e"}).find(GET, "/1/2/3/4/5").try(&.params).should eq({"a" => "1", "b" => "2", "c" => "3", "d" => "4", "e" => "5"})
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

    it "finds nested routes of one method, each with its own parameter names" do
      routes = tree({GET, "/posts/new"}, {GET, "/posts/:id"}, {GET, "/posts/:post_id/comments"}, {GET, "/posts/:post_id/comments/:id"})

      payload(routes, GET, "/posts/new").should eq "Get /posts/new"
      routes.find(GET, "/posts/1").try(&.params).should eq({"id" => "1"})
      routes.find(GET, "/posts/1/comments").try(&.params).should eq({"post_id" => "1"})
      routes.find(GET, "/posts/1/comments/2").try(&.params).should eq({"post_id" => "1", "id" => "2"})
    end

    it "reads a : or * inside a segment literally, as the OpenAPI document does" do
      routes = tree({GET, "/users:search"}, {GET, "/f/report-:id"}, {GET, "/a*b"})

      payload(routes, GET, "/users:search").should eq "Get /users:search"
      routes.find(GET, "/f/report-:id").try(&.params).should be_nil
      payload(routes, GET, "/a*b").should eq "Get /a*b"
      payload(routes, GET, "/usersfoo").should be_nil
      payload(routes, GET, "/f/report-7").should be_nil
      payload(routes, GET, "/axb").should be_nil
    end

    it "lets a declared route name a parameter unlike the HEAD and OPTIONS routes Router#get adds" do
      routes = tree({GET, "/posts/:id"}, {HEAD, "/posts/:id"}, {OPTIONS, "/posts/:id"})
      routes.add OPTIONS, "/posts/:post_id/comments", "Options comments"
      routes.add HEAD, "/posts/:post_id/comments", "Head comments"

      routes.find(OPTIONS, "/posts/1/comments").try(&.params).should eq({"post_id" => "1"})
      routes.find(HEAD, "/posts/1/comments").try(&.params).should eq({"post_id" => "1"})
      routes.find(HEAD, "/posts/1").try(&.params).should eq({"id" => "1"})
    end

    it "interns the parameter names and allocates only the values and the params hash" do
      routes = Tree.new
      100.times { |i| routes.add GET, "/api/v1/resource#{i}/:id", "resource#{i}" }
      names = {"/api/v1/resource1/1", "/api/v1/resource2/2"}.map { |path| routes.find(GET, path).try(&.params).try(&.keys.first) }

      names.first.should_not be_nil
      names.first.should be names.last
      value = "123".to_slice
      by_hand = HotPath.bytes_per_call { Hash(String, String).new["id"] = String.new(value) }
      found = HotPath.bytes_per_call { routes.find(GET, "/api/v1/resource57/123") }

      # Within less than the smallest heap object (16 B): GC statistics add a byte or two of noise per call
      found.should be_close(by_hand, 8)
      found.should be < 216 # measured 205: a Hash grown to 4 entries (112 B), not the 8 a capacity asks for (208 B)
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

    it "keeps taking deep paths after a shallower route is added, in either order" do
      glob_first = tree({GET, "/files/*path"}, {GET, "/files/new"})
      glob_last = tree({GET, "/files/new"}, {GET, "/files/*path"})

      glob_first.find(GET, "/files/a/b/c").try(&.params).should eq({"path" => "a/b/c"})
      glob_last.find(GET, "/files/a/b/c").try(&.params).should eq({"path" => "a/b/c"})
    end

    it "captures the rest of a path of 30 to 33 segments, either side of the stack's last offset" do
      routes = tree({GET, "/g/*rest"})

      (30..33).each do |segments|
        rest = (["s"] * (segments - 1)).join('/')
        routes.find(GET, "/g/#{rest}").try(&.params).should eq({"rest" => rest})
      end
    end

    it "refuses a glob before the last segment" do
      expect_raises(Tree::Error, "/a/*rest/b: a glob must be the last segment") { tree({GET, "/a/*rest/b"}) }
    end
  end

  describe "edge rules" do
    it "ignores a trailing slash on the request and on the route, as Router does with radix" do
      routes = tree({GET, "/"}, {GET, "/users"}, {GET, "/posts/"}, {GET, "/a/:id/"})

      payload(routes, GET, "/users/").should eq "Get /users"
      payload(routes, GET, "/users//").should eq "Get /users"
      payload(routes, GET, "/posts").should eq "Get /posts/"
      payload(routes, GET, "/posts/").should eq "Get /posts/"
      routes.find(GET, "/a/1/").try(&.params).should eq({"id" => "1"})
      payload(routes, GET, "//").should eq "Get /"
      payload(routes, GET, "").should eq "Get /"
    end

    it "refuses the same method and path twice, trailing slash or not" do
      routes = tree({GET, "/hello"}, {POST, "/hello/"})

      expect_raises(Tree::DuplicateError, "GET /hello/ is already routed as /hello") { routes.add GET, "/hello/", "again" }
      expect_raises(Tree::DuplicateError, "POST /hello is already routed as /hello/") { routes.add POST, "/hello", "again" }
    end

    it "refuses two routes of one method and shape whatever their parameter names, naming both paths" do
      routes = tree({GET, "/a/:id"}, {GET, "/f/*path"})

      expect_raises(Tree::DuplicateError, "GET /a/:name is already routed as /a/:id") { routes.add GET, "/a/:name", "x" }
      expect_raises(Tree::DuplicateError, "GET /f/*rest is already routed as /f/*path") { routes.add GET, "/f/*rest", "x" }
    end

    it "refuses a route path that does not start with a slash" do
      expect_raises(Tree::Error, %(route path "users" must start with /)) { tree({GET, "users"}) }
      expect_raises(Tree::Error, %(route path "" must start with /)) { tree({GET, ""}) }
    end
  end
end

private struct TableEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
  end
end

private alias Found = {String, Hash(String, String)}?
private alias RouteTree = Azu::Router::Tree(Azu::Router::Route)

private PUT   = Azu::Method::Put
private PATCH = Azu::Method::Patch
private DEL   = Azu::Method::Delete
private WS    = Azu::Method::WebSocket
private NONE  = {} of String => String

# Routes as the specs declare them: a method is a Router#add, a verb (or "root", "mount") calls Router's method of that
# name, so `get` adds HEAD and OPTIONS too and a mount adds its two routes for every method.
private BENCH = [{"get", "/plaintext"}, {"get", "/json"}, {"get", "/template"}] +
                (0...100).map { |i| {"get", "/api/v1/resource#{i}/:id"} } +
                [{"get", "/db/item/:id"}, {"get", "/db/items"}, {WS, "/ws"}]
private MOUNTED = BENCH + [{"mount", "/admin"}]
private ROOTED  = [{"get", "/plain"}, {GET, "/struct"}, {"root", "/"}]
private REST    = [{GET, "/users"}, {GET, "/users/:id"}, {POST, "/users"}, {PUT, "/users/:id"}, {DEL, "/users/:id"}]
private NESTED  = [{GET, "/users/:user_id/posts"}, {GET, "/users/:user_id/posts/:post_id"}, {POST, "/users/:user_id/posts"}]
private SHAPES  = [{GET, "/users/new"}, {GET, "/users/:id"}, {GET, "/a/b/c"}, {GET, "/a/:x/d"}]
private LONG    = "/" + "a" * 1000

# What the tree finds through the routes Router registers for route tables of spec/azu/router_spec.cr, the bench app
# (benchmark/apps/azu/src/app.cr) without and with a mount, and precedence shapes. Each is what radix 0.4.1 found
# when the router used it, as a differential spec of every table, probe and method checked before radix was removed:
# {routes, method, request path, {the route's resource, its params} or nil}.
private EXPECTED = [
  {ROOTED, GET, "/", {"/get/", NONE}}, {ROOTED, GET, "//", {"/get/", NONE}},
  {ROOTED, HEAD, "/plain/", {"/head/plain", NONE}}, {ROOTED, POST, "/plain", nil},
  {BENCH, GET, "/api/v1/resource57/123", {"/get/api/v1/resource57/:id", {"id" => "123"}}},
  {BENCH, OPTIONS, "/api/v1/resource57/123/", {"/options/api/v1/resource57/:id", {"id" => "123"}}},
  {BENCH, GET, "/api/v1/resource57", nil}, {BENCH, GET, "/api/v1/resource57/123/x", nil},
  {BENCH, GET, "/db/items", {"/get/db/items", NONE}}, {BENCH, GET, "/db/item", nil},
  {BENCH, WS, "/ws", {"/ws/ws", NONE}}, {BENCH, GET, "/ws", nil}, {BENCH, GET, "/s" * 40, nil},
  {MOUNTED, GET, "/admin", {"/get/admin", NONE}}, {MOUNTED, GET, "/adminx", nil},
  {MOUNTED, DEL, "/admin/a/b/", {"/delete/admin/*mount_path", {"mount_path" => "a/b"}}},
  {MOUNTED, WS, "/admin" + "/s" * 40, {"/ws/admin/*mount_path", {"mount_path" => (["s"] * 40).join('/')}}},
  {REST, PUT, "/users/1", {"/put/users/:id", {"id" => "1"}}}, {REST, PATCH, "/users/1", nil},
  {NESTED, GET, "/users/1/posts/2", {"/get/users/:user_id/posts/:post_id", {"user_id" => "1", "post_id" => "2"}}},
  {NESTED, GET, "/users//posts", {"/get/users/:user_id/posts", {"user_id" => ""}}},
  {NESTED, POST, "/users/a%2Fb/posts", {"/post/users/:user_id/posts", {"user_id" => "a%2Fb"}}},
  {SHAPES, GET, "/users/new", {"/get/users/new", NONE}}, {SHAPES, GET, "/users/newx", {"/get/users/:id", {"id" => "newx"}}},
  {SHAPES, GET, "/a/b/d", {"/get/a/:x/d", {"x" => "b"}}}, {[{GET, LONG}], GET, LONG, {"/get#{LONG}", NONE}},
]

# Where the tree differs on purpose from radix 0.4.1, which the router used before it, all GET: {routes, request path,
# what the tree finds}; what radix found is in the comment.
private DIFFERENCES = [
  # radix also kept "id" => "a", the parameter of a branch it had backtracked out of
  {[{GET, "/files/:id/meta"}, {GET, "/files/*path"}], "/files/a/b", {"/get/files/*path", {"path" => "a/b"}}},
  # the same below a mount whose prefix routes share: radix added "id" => "1"
  {[{"get", "/api/v1/resource5/:id"}, {"mount", "/api"}], "/api/v1/resource5/1/x",
   {"/get/api/*mount_path", {"mount_path" => "v1/resource5/1/x"}}},
  # radix found nothing: an empty glob was missed once another route had split the node before it
  {[{GET, "/files/*path"}, {GET, "/files/new"}], "/files", {"/get/files/*path", {"path" => ""}}},
  # radix found neither nested route (after a static sibling such as /posts/new it raised SharedKeyError instead)
  {[{GET, "/posts/:id"}, {GET, "/posts/:post_id/comments"}], "/posts/1", {"/get/posts/:id", {"id" => "1"}}},
  {[{GET, "/posts/:id"}, {GET, "/posts/:post_id/comments"}], "/posts/1/comments",
   {"/get/posts/:post_id/comments", {"post_id" => "1"}}},
  # radix read a parameter inside a segment ("search" => "foo", "id" => "7"); the tree a literal, as openapi/document.cr
  {[{GET, "/users:search"}], "/usersfoo", nil},
  {[{GET, "/f/report-:id"}], "/f/report-7", nil},
]

# GET routes radix 0.4.1 accepted and the tree refuses: {paths, the tree's error}.
private REFUSED = [
  {["/a/:id", "/a/:name"], "GET /a/:name is already routed as /a/:id"}, # radix accepted both and found neither
  {["/hello", "/hello/"], "GET /hello/ is already routed as /hello"},   # radix never found the second
  {["users"], %(route path "users" must start with /)},                 # radix never found it
  {["/a/*rest/b"], "/a/*rest/b: a glob must be the last segment"},      # radix named the glob "rest/b"
]

private def router(routes : Array) : Azu::Router
  router = Azu::Router.new
  routes.each do |(how, path)|
    case how
    in Azu::Method then router.add path, TableEndpoint.new, how
    in String
      case how
      when "root"  then router.root TableEndpoint.new
      when "mount" then router.mount Azu::Configuration.new, at: path
      else              router.register how, path, TableEndpoint.new
      end
    end
  end
  router
end

# What a tree of the routes Router registered finds: the route's resource names it.
private def tree_find(routes : Array, method : Azu::Method, path : String) : Found
  tree = router(routes).registered_routes.each_with_object(RouteTree.new) { |route, tree| tree.add route.method, route.path, route }
  tree.find(method, path).try { |found| {found.payload.resource, found.params || {} of String => String} }
end

describe "Azu::Router::Tree through the routes Router registers" do
  it "finds what radix found for route tables of the router specs, the bench app and a mount" do
    mismatches = EXPECTED.compact_map do |(routes, method, path, expected)|
      found = tree_find(routes, method, path)
      "#{method} #{path.inspect}: found #{found}, expected #{expected}" unless found == expected
    end

    mismatches.should be_empty
  end

  it "differs from radix where radix found the wrong route or params" do
    DIFFERENCES.each { |(routes, path, expected)| tree_find(routes, GET, path).should eq expected }
  end

  it "refuses routes radix accepted without a word" do
    REFUSED.each do |(paths, message)|
      routes = Tree.new

      expect_raises(Azu::Router::Tree::Error, message) { paths.each { |path| routes.add GET, path, path } }
    end
  end
end
