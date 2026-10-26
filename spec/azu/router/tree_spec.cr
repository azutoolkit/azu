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

private struct DiffEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
  end
end

private alias Declared = {Azu::Method | String, String}
private alias Found = {String, Hash(String, String)}?
private alias RouteTree = Azu::Router::Tree(Azu::Router::Route)

private PUT = Azu::Method::Put
private DEL = Azu::Method::Delete
private WS  = Azu::Method::WebSocket

# Routes as the specs declare them: a method is a Router#add, a verb (or "root", "mount") calls Router's method of that
# name, so `get` adds HEAD and OPTIONS too and a mount adds its two routes for every method.
private BENCH = [{"get", "/plaintext"}, {"get", "/json"}, {"get", "/template"}] +
                (0...100).map { |i| {"get", "/api/v1/resource#{i}/:id"} } +
                [{"get", "/db/item/:id"}, {"get", "/db/items"}, {WS, "/ws"}]
# Each distinct route table of spec/azu/router_spec.cr, the bench app's (benchmark/apps/azu/src/app.cr) without and
# with a mount, and precedence and backtracking shapes.
private TABLES = [
  [{"get", "/plain"}, {GET, "/struct"}, {"root", "/"}], [{GET, "/"}], [{POST, "/submit"}], [{GET, "/"}, {POST, "/api"}],
  [{GET, "/users"}, {POST, "/users"}, {PUT, "/users"}, {DEL, "/users"}], [{GET, "/test"}], [{GET, "/users/:id"}],
  [{GET, "/api/v1/users"}], [{WS, "/ws"}], [] of Declared, [{GET, "/duplicate"}],
  [{GET, "/users"}, {GET, "/users/:id"}, {POST, "/users"}, {PUT, "/users/:id"}, {DEL, "/users/:id"}],
  [{GET, "/users/:user_id/posts"}, {GET, "/users/:user_id/posts/:post_id"}, {POST, "/users/:user_id/posts"}],
  [{GET, "/search"}, {GET, "/search/:query"}], [{GET, "/api/v1/users"}, {GET, "/api/v1/users/:id"}],
  [{GET, "/" + "a" * 1000}], (0...100).map { |i| {GET, "/route#{i}"} }, [{"get", "/hello"}], [{WS, "/ws-test"}],
  %w(get post put patch delete).map { |verb| {Azu::Method.parse(verb), "/test-#{verb}"} }, [{"get", "/test"}],
  [{"get", "/cached-test"}], (1..100).map { |i| {"get", "/test#{i}"} }, (1..10).map { |i| {"get", "/concurrent#{i}"} },
  (0...10).flat_map { |n| (1..5).map { |i| {"get", "/concurrent_write#{n}_#{i}"} } },
  (1..20).map { |i| {"get", "/perf#{i}"} }, [{"post", "/data"}], [{"put", "/update"}],
  %w(get post put patch delete).map { |verb| {verb, "/posts/:id"} },
  BENCH, BENCH + [{"mount", "/admin"}],
  [{GET, "/users/new"}, {GET, "/users/:id"}, {GET, "/a/b/c"}, {GET, "/a/:x/d"}],
]

# Where the tree differs from radix 0.4.1 on purpose, all GET: {routes, request path, tree's find, radix's find}.
private FIND_DIFFERENCES = [
  # radix keeps the parameter of a branch it backtracked out of
  {[{GET, "/files/:id/meta"}, {GET, "/files/*path"}], "/files/a/b",
   {"/get/files/*path", {"path" => "a/b"}}, {"/get/files/*path", {"id" => "a", "path" => "a/b"}}},
  # the same below a mount whose prefix routes share
  {[{"get", "/api/v1/resource5/:id"}, {"mount", "/api"}], "/api/v1/resource5/1/x",
   {"/get/api/*mount_path", {"mount_path" => "v1/resource5/1/x"}},
   {"/get/api/*mount_path", {"id" => "1", "mount_path" => "v1/resource5/1/x"}}},
  # radix misses an empty glob once another route has split the node before it
  {[{GET, "/files/*path"}, {GET, "/files/new"}], "/files", {"/get/files/*path", {"path" => ""}}, nil},
  # radix finds neither nested route (after a static sibling such as /posts/new it raises SharedKeyError instead)
  {[{GET, "/posts/:id"}, {GET, "/posts/:post_id/comments"}], "/posts/1", {"/get/posts/:id", {"id" => "1"}}, nil},
  {[{GET, "/posts/:id"}, {GET, "/posts/:post_id/comments"}], "/posts/1/comments",
   {"/get/posts/:post_id/comments", {"post_id" => "1"}}, nil},
  # radix reads a parameter inside a segment, the tree a literal (as openapi/document.cr does)
  {[{GET, "/users:search"}], "/usersfoo", nil, {"/get/users:search", {"search" => "foo"}}},
  {[{GET, "/f/report-:id"}], "/f/report-7", nil, {"/get/f/report-:id", {"id" => "7"}}},
]

# GET routes radix accepts and the tree refuses: {paths, the tree's error}.
private ADD_DIFFERENCES = [
  {["/a/:id", "/a/:name"], "GET /a/:name is already routed as /a/:id"}, # radix accepts both and finds neither
  {["/hello", "/hello/"], "GET /hello/ is already routed as /hello"},   # radix never finds the second
  {["users"], %(route path "users" must start with /)},                 # radix never finds it
  {["/a/*rest/b"], "/a/*rest/b: a glob must be the last segment"},      # radix names the glob "rest/b"
]

private def router(routes : Array) : Azu::Router
  router = Azu::Router.new
  routes.each do |(how, path)|
    case how
    in Azu::Method then router.add path, DiffEndpoint.new, how
    in String
      case how
      when "root"  then router.root DiffEndpoint.new
      when "mount" then router.mount Azu::Configuration.new, at: path
      else              router.register how, path, DiffEndpoint.new
      end
    end
  end
  router
end

private def tree(router : Azu::Router) : RouteTree
  router.registered_routes.each_with_object(RouteTree.new) { |route, tree| tree.add route.method, route.path, route }
end

# What radix finds for a request, keyed as Router#process keys it.
private def radix_find(router : Azu::Router, method : Azu::Method, path : String) : Found
  result = router.radix.find((method.web_socket? ? "/ws" : "/#{method.to_s.downcase}") + path.rstrip('/'))
  {result.payload.resource, result.params} if result.found?
end

private def tree_find(tree : RouteTree, method : Azu::Method, path : String) : Found
  tree.find(method, path).try { |found| {found.payload.resource, found.params || {} of String => String} }
end

private def concrete(path : String, value : String, rest : String) : String
  path.split('/').map { |segment| segment[0]? == ':' ? value : (segment[0]? == '*' ? rest : segment) }.join('/')
end

# Requests around each route: a hit, a trailing slash, one more segment, a longer last segment, empty parameters, the
# parent path and a deep path; then paths of no route, or of a backtracking one.
private def probes(router : Azu::Router) : Array(String)
  router.registered_routes.flat_map do |route|
    hit = concrete(route.path, "42", "a/b")
    [hit, hit + "/", hit + "/x", hit + "x", concrete(route.path, "", ""), hit.rpartition('/')[0], hit + "/s" * 40]
  end.uniq + ["", "/", "//", "/nope", "/s" * 40, "/a%2Fb", "/a/b/d"]
end

describe "Azu::Router::Tree against radix" do
  it "finds the payload and params radix finds, for every table, probe and method" do
    with_params = 0
    mismatches = TABLES.flat_map do |routes|
      router = router(routes)
      tree = tree(router)
      probes(router).flat_map do |path|
        Azu::Method.values.compact_map do |method|
          found, expected = tree_find(tree, method, path), radix_find(router, method, path)
          with_params += 1 if expected.try { |(_, params)| !params.empty? }
          "#{routes.first?} #{method} #{path.inspect}: tree #{found}, radix #{expected}" unless found == expected
        end
      end
    end

    mismatches.should be_empty
    with_params.should be > 1000 # the probes reach parameter routes, not only misses
  end

  it "differs from radix where radix finds the wrong route or params" do
    FIND_DIFFERENCES.each do |(routes, path, by_tree, by_radix)|
      router = router(routes)

      tree_find(tree(router), GET, path).should eq by_tree
      radix_find(router, GET, path).should eq by_radix
    end
  end

  it "refuses routes radix accepts without a word" do
    ADD_DIFFERENCES.each do |(paths, message)|
      router = router(paths.map { |path| {GET, path} })

      expect_raises(Azu::Router::Tree::Error, message) { tree(router) }
    end
  end
end
