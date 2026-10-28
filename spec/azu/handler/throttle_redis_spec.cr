require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

private THROTTLE_REDIS_URL = ENV.fetch("AZU_TEST_REDIS_URL", "redis://localhost:6379/0")

private def throttle_redis_available? : Bool
  client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: THROTTLE_REDIS_URL, connect_timeout: 1.second, command_timeout: 1.second))
  client.ping
rescue
  false
ensure
  client.try(&.close)
end

private def redis_store(prefix : String) : Azu::Handler::Throttle::Store::Redis
  Azu::Handler::Throttle::Store::Redis.new(THROTTLE_REDIS_URL, prefix)
end

private def throttled(store : Azu::Handler::Throttle::Store, threshold : Int32 = 2) : Azu::Handler::Throttle
  handler = Azu::Handler::Throttle.new(60, 30, threshold, [] of String, [] of String, store: store)
  handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
  handler
end

private def status_of(handler : Azu::Handler::Throttle, address : String) : Int32
  context, _ = create_context_with_remote_addr("GET", "/limited", address)
  handler.call(context)
  context.response.status_code
end

describe Azu::Handler::Throttle::Store::Redis do
  it "counts every instance of the app together, and blocks for the duration" do
    pending!("Redis is not reachable on #{THROTTLE_REDIS_URL}") unless throttle_redis_available?
    store = redis_store("spec:throttle:#{Random::Secure.hex(4)}:")
    store.reset
    begin
      first = throttled(store)
      second = throttled(store) # another process of the same app, as far as Redis can tell

      status_of(first, "10.7.0.1").should eq 200
      status_of(second, "10.7.0.1").should eq 200
      refused, _ = create_context_with_remote_addr("GET", "/limited", "10.7.0.1")
      second.call(refused)
      refused.response.status_code.should eq 429
      refused.response.headers["Retry-After"].should eq "30"
      status_of(first, "10.7.0.1").should eq 429
      status_of(first, "10.7.0.2").should eq 200 # another client is not affected

      store.reset
      status_of(first, "10.7.0.1").should eq 200
    ensure
      store.reset
    end
  end

  it "lets a client through again once its block has expired" do
    pending!("Redis is not reachable on #{THROTTLE_REDIS_URL}") unless throttle_redis_available?
    store = redis_store("spec:throttle:#{Random::Secure.hex(4)}:")
    handler = Azu::Handler::Throttle.new(60, 1, 1, [] of String, [] of String, store: store)
    handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
    begin
      status_of(handler, "10.7.2.1").should eq 200
      refused, _ = create_context_with_remote_addr("GET", "/limited", "10.7.2.1")
      handler.call(refused)
      refused.response.status_code.should eq 429
      refused.response.headers["Retry-After"].should eq "1"
      sleep 1.2.seconds
      status_of(handler, "10.7.2.1").should eq 200
    ensure
      store.reset
    end
  end

  it "counts in this process while Redis cannot be reached, backing off before asking again" do
    backend = ::Log::MemoryBackend.new
    log = ::Log.new("throttle_redis_spec", backend, :warn)
    config = Azu::Redis::Config.new(url: "redis://127.0.0.1:1/0", pool_size: 1, connect_timeout: 200.milliseconds, command_timeout: 200.milliseconds, retry: Azu::Redis::Retry.new(retries: 0))
    client = Azu::Redis::Client.new(config)
    store = Azu::Handler::Throttle::Store::Redis.new(client, "spec:throttle:down:", log)
    begin
      handler = throttled(store, 1) # one request passes, the second is refused, both counted by the memory fallback
      status_of(handler, "10.7.1.1").should eq 200
      store.backing_off?.should be_true
      status_of(handler, "10.7.1.1").should eq 429
      status_of(handler, "10.7.1.2").should eq 200
      backend.entries.map(&.message).count(&.includes?("throttle store unavailable")).should eq 1
    ensure
      client.close
    end
  end

  it "is what THROTTLE_STORE=redis selects" do
    previous = ENV["THROTTLE_STORE"]?
    ENV["THROTTLE_STORE"] = "redis"
    begin
      Azu::Handler::Throttle::Store.from_env.should be_a Azu::Handler::Throttle::Store::Redis
      ENV["THROTTLE_STORE"] = "memory"
      Azu::Handler::Throttle::Store.from_env.should be_a Azu::Handler::Throttle::Store::Memory
      ENV["THROTTLE_STORE"] = "rediss"
      expect_raises(ArgumentError, /THROTTLE_STORE/) { Azu::Handler::Throttle::Store.from_env }
    ensure
      previous ? (ENV["THROTTLE_STORE"] = previous) : ENV.delete("THROTTLE_STORE")
      Azu::Redis.shutdown
    end
  end
end
