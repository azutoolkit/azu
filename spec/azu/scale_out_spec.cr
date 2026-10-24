require "../spec_helper"
require "../support/spark_helpers"
require "http/client"
require "file_utils"
require "digest/sha1"

# Scale-out: two real OS processes of spec/fixtures/scale_node.cr (compiled once) share one Redis. They are
# separate processes, not two apps in one, so the spec exercises what production has: separate PubSub
# listener connections, separate heartbeats and a node that disappears without running any teardown.
#
# Opt-in: set AZU_TEST_SCALE=1 (CI does), since compiling the fixture takes about 30 seconds. The binary is cached
# in the temp directory under a hash of src/ and the fixture, so only the first run after a change compiles. Needs
# a Redis (AZU_TEST_REDIS_URL, default localhost:6379) and `crystal` on the PATH; it is pending otherwise.
SCALE_REDIS_URL = ENV.fetch("AZU_TEST_REDIS_URL", "redis://localhost:6379/0")
SCALE_TTL       = 3.seconds

private def scale_redis_available? : Bool
  redis = Redis.new(url: SCALE_REDIS_URL, reconnect: false)
  redis.ping
  redis.close
  true
rescue
  false
end

private def free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  server.local_address.port.tap { server.close }
end

# The compiled fixture, reused while neither src/ nor the fixture changed.
private def compile_node : String
  root = File.expand_path("../..", __DIR__)
  digest = Digest::SHA1.new
  (Dir.glob(File.join(root, "{src/**/*.cr,shard.yml,shard.lock,lib/*/shard.yml,spec/fixtures/scale_node.cr}")).sort).each { |path| digest << File.read(path) }
  directory = File.join(Dir.tempdir, "azu-scale-cache", digest.hexfinal)
  binary = File.join(directory, "scale_node")
  return binary if File.exists?(binary)

  Dir.mkdir_p(directory)
  building = "#{binary}.#{Random::Secure.hex(4)}"
  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-debug", "-o", building, "spec/fixtures/scale_node.cr"], chdir: root, output: output, error: output)
  fail "could not compile spec/fixtures/scale_node.cr:\n#{output}" unless status.success?
  File.rename(building, binary)
  binary
end

private class Node
  getter port : Int32
  @killed = false

  def initialize(binary : String, name : String, prefix : String, log : String)
    @port = free_port
    env = {"NODE" => name, "PORT" => @port.to_s, "REDIS_URL" => SCALE_REDIS_URL, "PREFIX" => prefix, "TTL_MS" => SCALE_TTL.total_milliseconds.to_i.to_s}
    @process = Process.new(binary, env: env, output: File.open(log, "w"), error: Process::Redirect::Inherit)
  end

  def ready? : Bool
    wait_until(20.seconds) { get("/health") == "ok" }
  end

  def get(path : String) : String?
    response = HTTP::Client.get("http://127.0.0.1:#{port}#{path}")
    response.body if response.success?
  rescue IO::Error | Socket::Error
    nil
  end

  def presence : Hash(String, Array(String))
    (get("/presence").try { |body| Hash(String, Array(String)).from_json(body) }) || {} of String => Array(String)
  end

  def kill : Nil
    return if @killed
    @killed = true
    @process.signal(Signal::KILL)
    @process.wait
  end
end

# Next frame of *client* matching the block, within *timeout*.
private def frame_where(client : WsProbe, timeout : Time::Span = 5.seconds, & : String -> Bool) : String?
  deadline = Time.instant + timeout
  while (remaining = deadline - Time.instant) > Time::Span.zero
    return unless frame = client.receive(remaining)
    return frame if yield frame
  end
end

describe "scale-out" do
  it "shares broadcasts and presence between two processes and expires a node that was killed" do
    pending!("set AZU_TEST_SCALE=1 to run the two-process scale-out spec") unless ENV["AZU_TEST_SCALE"]? == "1"
    pending!("Redis is not reachable on #{SCALE_REDIS_URL}") unless scale_redis_available?
    pending!("crystal is not on the PATH") unless Process.find_executable("crystal")

    directory = File.join(Dir.tempdir, "azu-scale-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(directory)
    prefix = "azu:test:scale:#{Random::Secure.hex(4)}:"
    nodes = [] of Node
    begin
      binary = compile_node
      node_a = Node.new(binary, "node-a", prefix, File.join(directory, "a.log")).tap { |node| nodes << node }
      node_b = Node.new(binary, "node-b", prefix, File.join(directory, "b.log")).tap { |node| nodes << node }
      node_a.ready?.should be_true
      node_b.ready?.should be_true

      alice = WsProbe.new(node_a.port, "/?user=alice")
      bob = WsProbe.new(node_b.port, "/?user=bob")

      # Presence shows both users from either node, each on the node it connected to.
      expected = {"alice" => ["node-a"], "bob" => ["node-b"]}
      wait_until(5.seconds) { node_a.presence == expected && node_b.presence == expected }.should be_true
      frame_where(alice, &.includes?(%("arrived":["bob"]))).should_not be_nil

      # A broadcast reaches the other node's client, in both directions.
      alice.send("hello from a")
      frame_where(bob, &.starts_with?("msg:")).should eq "msg:alice@node-a:hello from a"
      bob.send("hello from b")
      frame_where(alice, &.starts_with?("msg:bob")).should eq "msg:bob@node-b:hello from b"

      # SIGKILL runs no teardown: bob's entry leaves node A's list when node B's lease runs out.
      node_b.kill
      wait_until(SCALE_TTL * 5) { node_a.presence == {"alice" => ["node-a"]} }.should be_true
      frame_where(alice, &.includes?(%("departed":["bob"]))).should_not be_nil
    ensure
      nodes.each(&.kill)
      redis = Redis.new(url: SCALE_REDIS_URL, reconnect: false)
      redis.del("#{prefix}presence:nodes", "#{prefix}presence:t:room")
      redis.close
      FileUtils.rm_rf(directory)
    end
  end
end
