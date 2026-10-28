require "../spec_helper"
require "log/spec"

REDIS_UTIL_URL = ENV.fetch("AZU_TEST_REDIS_URL", "redis://localhost:6379/0")

private def redis_util_available? : Bool
  redis = Redis.new(url: REDIS_UTIL_URL, reconnect: false, connect_timeout: 0.5.seconds)
  redis.ping
  redis.close
  true
rescue
  false
end

private class FakeConnection
  getter? closed = false
  property? healthy = true

  def close : Nil
    @closed = true
  end
end

private def fake_pool(capacity : Int32 = 2, timeout : Time::Span = 50.milliseconds, health_check_after : Time::Span = 30.seconds,
                      created : Array(FakeConnection) = [] of FakeConnection, broken : Proc(Exception, Bool) = ->(_error : Exception) { true })
  Azu::Redis::Pool(FakeConnection).new(capacity, timeout, -> { FakeConnection.new.tap { |connection| created << connection } },
    health_check_after, ->(connection : FakeConnection) { connection.healthy? }, broken)
end

# A free port nothing listens on, so a connect is refused at once.
private UNREACHABLE = "redis://127.0.0.1:1/0"

private def live_config(**options) : Azu::Redis::Config
  Azu::Redis::Config.new(REDIS_UTIL_URL, **options)
end

private def live_redis(&)
  pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
  client = Azu::Redis::Client.new(live_config(name: "spec"))
  begin
    yield client
  ensure
    client.close
  end
end

describe Azu::Redis::Config do
  it "reads REDIS_URL and the tuning variables in one place" do
    config = Azu::Redis::Config.from_env({
      "REDIS_URL" => "redis://cache.internal:6380/3", "REDIS_POOL_SIZE" => "9", "REDIS_TIMEOUT" => "1.5",
      "REDIS_CONNECT_TIMEOUT" => "2", "REDIS_POOL_TIMEOUT" => "0.5", "REDIS_RETRIES" => "3", "REDIS_PREFIX" => "app:",
      "REDIS_TLS_CA_FILE" => "/etc/ca.pem", "REDIS_TLS_VERIFY" => "false",
    })

    config.url.should eq "redis://cache.internal:6380/3"
    config.pool_size.should eq 9
    config.command_timeout.should eq 1.5.seconds
    config.connect_timeout.should eq 2.seconds
    config.checkout_timeout.should eq 500.milliseconds
    config.retry.retries.should eq 3
    config.prefix.should eq "app:"
    config.tls_ca_file.should eq "/etc/ca.pem"
    config.tls_verify?.should be_false
  end

  it "defaults every setting" do
    config = Azu::Redis::Config.from_env({} of String => String)

    config.url.should eq "redis://localhost:6379/0"
    {config.pool_size, config.command_timeout, config.retry.retries, config.tls_verify?}.should eq({5, 5.seconds, 1, true})
  end

  it "prefers a subsystem URL over REDIS_URL" do
    env = {"REDIS_URL" => "redis://shared/0", "PUBSUB_REDIS_URL" => "redis://pubsub/0"}

    Azu::Redis::Config.url_from_env("PRESENCE_REDIS_URL", "PUBSUB_REDIS_URL", env: env).should eq "redis://pubsub/0"
    Azu::Redis::Config.url_from_env("CACHE_REDIS_URL", env: env).should eq "redis://shared/0"
    Azu::Redis::Config.url_from_env("CACHE_REDIS_URL", env: {} of String => String).should eq "redis://localhost:6379/0"
  end

  it "names the variable, never its value, when one is malformed" do
    error = expect_raises(ArgumentError) { Azu::Redis::Config.from_env({"REDIS_POOL_SIZE" => "hunter2"}) }
    error.message.to_s.should contain "REDIS_POOL_SIZE"
    error.message.to_s.should_not contain "hunter2"
    expect_raises(ArgumentError, /REDIS_TIMEOUT/) { Azu::Redis::Config.from_env({"REDIS_TIMEOUT" => "0"}) }
  end

  it "rejects a pool without room and a name with whitespace" do
    expect_raises(ArgumentError) { Azu::Redis::Config.new(pool_size: 0) }
    expect_raises(ArgumentError) { Azu::Redis::Config.new(name: "two words") }
  end

  it "redacts the password in the URL, inspect, to_s and the client" do
    config = Azu::Redis::Config.new(url: "rediss://deploy:s3cr3t-pw@redis.example.com:6380/4")

    config.redacted_url.should eq "rediss://deploy:***@redis.example.com:6380/4"
    [config.inspect, config.to_s, "#{config}", Azu::Redis::Client.new(config).inspect].each do |text|
      text.should_not contain "s3cr3t-pw"
      text.should contain "redis.example.com"
    end
    Azu::Redis::Config.redact("redis://:pw@h/0").should eq "redis://:***@h/0"
    Azu::Redis::Config.redact("redis://h:6379/0").should eq "redis://h:6379/0"
  end

  it "shares a pool key only between equal connection settings" do
    base = Azu::Redis::Config.new
    base.pool_key.should eq base.copy_with(prefix: "other:", name: "other").pool_key
    base.pool_key.should_not eq base.copy_with(pool_size: 6).pool_key
    base.pool_key.should_not eq base.copy_with(command_timeout: 1.second).pool_key
    base.pool_key.should_not eq base.copy_with(url: "redis://other/0").pool_key
  end

  it "builds a TLS context only when asked to deviate from the default" do
    Azu::Redis::Config.new(url: "rediss://h/0").ssl_context.should be_nil
    Azu::Redis::Config.new(url: "rediss://h/0").tls?.should be_true
    Azu::Redis::Config.new(url: "redis://h/0").tls?.should be_false
    Azu::Redis::Config.new(url: "redis://h/0", tls_verify: false, tls_ca_file: "/x.pem").tls?.should be_false
    Azu::Redis::Config.new(url: "redis://h/0", tls_verify: false).ssl_context.should be_nil
    context = nil
    Log.capture("Azu::Redis") do |logs|
      context = Azu::Redis::Config.new(url: "rediss://user:hunter2@h/0", tls_verify: false).ssl_context
      logs.check(:warn, /REDIS_TLS_VERIFY is off: the certificate of rediss:\/\/user:\*\*\*@h\/0 is not checked/)
      logs.empty
    end
    context.try(&.verify_mode).should eq OpenSSL::SSL::VerifyMode::NONE
  end
end

describe Azu::Redis::Retry do
  it "doubles from the base up to the cap" do
    policy = Azu::Redis::Retry.new(retries: 5, base: 10.milliseconds, max: 50.milliseconds, jitter: 0.0)

    (0..4).map { |attempt| policy.delay(attempt, 0.0) }.should eq [10, 20, 40, 50, 50].map(&.milliseconds)
    policy.delay(1000, 0.0).should eq 50.milliseconds
  end

  it "shortens the wait by up to the jitter fraction" do
    policy = Azu::Redis::Retry.new(base: 100.milliseconds, max: 1.second, jitter: 0.5)

    policy.delay(0, 0.0).should eq 100.milliseconds
    policy.delay(0, 1.0).should eq 50.milliseconds
    policy.delay(0, 0.5).should eq 75.milliseconds
  end

  it "counts attempts and can be switched off" do
    policy = Azu::Redis::Retry.new(retries: 2)
    {policy.retry?(0), policy.retry?(1), policy.retry?(2)}.should eq({true, true, false})
    Azu::Redis::Retry.none.retry?(0).should be_false
    expect_raises(ArgumentError) { Azu::Redis::Retry.new(retries: -1) }
    expect_raises(ArgumentError) { Azu::Redis::Retry.new(jitter: 1.5) }
  end
end

describe Azu::Redis::Pool do
  it "opens connections lazily, reuses them and never exceeds its capacity" do
    created = [] of FakeConnection
    pool = fake_pool(2, created: created)
    created.should be_empty

    pool.run { |_| }
    pool.run { |_| }
    created.size.should eq 1

    first = pool.checkout
    second = pool.checkout
    created.size.should eq 2
    pool.stats.in_use.should eq 2
    expect_raises(Redis::PoolTimeoutError) { pool.checkout }
    created.size.should eq 2

    pool.checkin(first)
    pool.checkout.should be first
    pool.checkin(second)
  end

  it "waits for a free connection up to the checkout timeout" do
    pool = fake_pool(1, 500.milliseconds)
    held = pool.checkout
    waiter = ::Channel(FakeConnection).new
    spawn { waiter.send(pool.checkout) }
    Fiber.yield

    pool.checkin(held)

    waiter.receive.should be held
  end

  it "times out when every connection stays checked out" do
    pool = fake_pool(1, 30.milliseconds)
    pool.checkout

    started = Time.instant
    expect_raises(Redis::PoolTimeoutError, /No free Redis connection/) { pool.checkout }
    (Time.instant - started).should be < 1.second
  end

  it "discards a connection whose use failed and frees its permit for a waiter" do
    created = [] of FakeConnection
    pool = fake_pool(1, 500.milliseconds, created: created)

    expect_raises(IO::Error) { pool.run { |_| raise IO::Error.new("reset") } }

    created.first.closed?.should be_true
    pool.stats.discarded.should eq 1
    pool.run(&.should_not(be(created.first)))
    created.size.should eq 2
  end

  it "keeps a connection when the error does not break it" do
    created = [] of FakeConnection
    pool = fake_pool(1, created: created, broken: ->(error : Exception) { error.is_a?(IO::Error) })

    expect_raises(ArgumentError) { pool.run { |_| raise ArgumentError.new("not the connection's fault") } }
    pool.run { |_| }

    created.size.should eq 1
    created.first.closed?.should be_false
    pool.stats.discarded.should eq 0
  end

  it "wakes a waiter when the connection it waits for is discarded" do
    created = [] of FakeConnection
    pool = fake_pool(1, 500.milliseconds, created: created)
    broken = pool.checkout
    waiter = ::Channel(FakeConnection).new
    spawn { waiter.send(pool.checkout) }
    Fiber.yield

    pool.discard(broken)

    waiter.receive.should_not be broken
  end

  it "gives the permit back when opening a connection fails" do
    attempts = 0
    pool = Azu::Redis::Pool(FakeConnection).new(1, 50.milliseconds, -> {
      attempts += 1
      raise IO::Error.new("refused") if attempts == 1
      FakeConnection.new
    })

    expect_raises(IO::Error) { pool.checkout }
    pool.run { |_| }.should be_nil
    pool.stats.open.should eq 1
  end

  it "probes a connection that sat idle and replaces it when the probe fails" do
    with_fake_clock do |clock|
      created = [] of FakeConnection
      pool = fake_pool(1, health_check_after: 10.seconds, created: created)
      pool.run { |_| }
      created.first.healthy = false

      pool.run { |_| }
      created.size.should eq 1

      clock.advance(11.seconds)
      pool.run(&.should_not(be(created.first)))
      created.first.closed?.should be_true
      created.size.should eq 2
    end
  end

  it "does not probe a connection that was used recently" do
    with_fake_clock do |clock|
      created = [] of FakeConnection
      pool = fake_pool(1, health_check_after: 10.seconds, created: created)
      pool.run { |_| }
      created.first.healthy = false
      clock.advance(5.seconds)

      pool.run(&.should(be(created.first)))
    end
  end

  it "closes idle connections at once, checked out ones when they return, and refuses new checkouts" do
    created = [] of FakeConnection
    pool = fake_pool(2, created: created)
    idle = pool.checkout
    pool.checkin(idle)
    borrowed = pool.checkout
    pool.checkout

    pool.close

    pool.closed?.should be_true
    pool.checkin(borrowed)
    borrowed.closed?.should be_true
    expect_raises(Azu::Redis::ClosedError) { pool.checkout }
    pool.close
  end

  it "fails the fibers waiting for a connection when it closes" do
    pool = fake_pool(1, 2.seconds)
    pool.checkout
    outcome = ::Channel(Exception?).new
    spawn do
      pool.checkout
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    Fiber.yield

    pool.close

    outcome.receive.should be_a Azu::Redis::ClosedError
  end

  it "ends adopted connections with the pool and refuses to adopt after" do
    pool = fake_pool
    adopted = pool.adopt(FakeConnection.new)
    other = pool.adopt(FakeConnection.new)
    pool.stats.adopted.should eq 2
    pool.release_adopted(other)
    other.closed?.should be_true

    pool.close

    adopted.closed?.should be_true
    expect_raises(Azu::Redis::ClosedError) { pool.adopt(FakeConnection.new) }
  end

  it "stays within its capacity under concurrent use" do
    created = [] of FakeConnection
    pool = fake_pool(3, 2.seconds, created: created)
    peak = 0
    current = 0
    done = ::Channel(Nil).new
    20.times do
      spawn do
        pool.run do |_|
          current += 1
          peak = {peak, current}.max
          sleep 1.millisecond
          current -= 1
        end
        done.send(nil)
      end
    end
    20.times { done.receive }

    peak.should be <= 3
    created.size.should be <= 3
  end
end

private def leave_early(pool : Azu::Redis::Pool(FakeConnection)) : Int32
  pool.run { |_| return 1 }
  2
end

describe Azu::Redis::Pool do
  it "discards a connection when the block is left by return, so the slot does not leak" do
    created = [] of FakeConnection
    pool = fake_pool(1, created: created)

    leave_early(pool).should eq 1

    created.first.closed?.should be_true
    pool.stats.in_use.should eq 0
    pool.stats.discarded.should eq 1
    pool.run { |_| }
    created.size.should eq 2
  end

  it "discards on any error when strict, even one that does not break a connection" do
    created = [] of FakeConnection
    pool = fake_pool(1, created: created, broken: ->(_error : Exception) { false })

    expect_raises(ArgumentError) { pool.run(strict: true) { |_| raise ArgumentError.new("x") } }

    created.first.closed?.should be_true
    pool.stats.discarded.should eq 1
  end
end

private def kill_all_clients : Nil
  killer = Redis.new(url: REDIS_UTIL_URL, reconnect: false)
  begin
    killer.command(["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"])
  ensure
    killer.close
  end
end

private def fill_pool(client : Azu::Redis::Client) : Nil
  client.run { |_| client.run { |_| client.run(&.ping) } }
end

describe Azu::Redis::Pool do
  it "drops every idle connection and frees their permits" do
    created = [] of FakeConnection
    pool = fake_pool(3, created: created)
    held = [pool.checkout, pool.checkout, pool.checkout]
    held.each { |connection| pool.checkin(connection) }

    pool.drop_idle

    created.all?(&.closed?).should be_true
    pool.stats.open.should eq 0
    3.times { pool.checkout }
    created.size.should eq 6
  end
end

# A ::Redis that never connects: `multi` and `pipelined` fail the way a block that raised would.
private class FailingRedis < ::Redis
  def initialize
    @host = "localhost"
    @port = 6379
    @unixsocket = nil
    @password = nil
    @database = nil
    @ssl = false
    @ssl_context = nil
    @dns_timeout = nil
    @connect_timeout = nil
    @reconnect = false
    @command_timeout = nil
    @namespace = ""
  end

  # The `yield`s make these overrides of the parent's block methods; they are never reached.
  def multi(&)
    raise ArgumentError.new("multi failed") unless @reconnect.nil?
    yield ::Redis::TransactionApi.allocate
    [] of ::Redis::RedisValue
  end

  def pipelined(&)
    raise ArgumentError.new("pipeline failed") unless @reconnect.nil?
    yield ::Redis::PipelineApi.allocate
    [] of ::Redis::RedisValue
  end

  def close
  end
end

private def failing_client(on_close : Proc(Nil)? = nil) : Azu::Redis::Client
  config = Azu::Redis::Config.new(url: UNREACHABLE, pool_size: 1, checkout_timeout: 50.milliseconds)
  pool = Azu::Redis::Pool(::Redis).new(1, 50.milliseconds, -> { FailingRedis.new.as(::Redis) },
    broken: ->(error : Exception) { Azu::Redis.connection_failure?(error) })
  Azu::Redis::Client.new(config, pool, on_close)
end

describe Azu::Redis::Client do
  it "discards the connection when a multi block fails with an error that is not about the connection" do
    client = failing_client

    expect_raises(ArgumentError, "multi failed") { client.multi { |_| } }

    client.stats.discarded.should eq 1
  end

  it "discards the connection when a pipelined block fails likewise" do
    client = failing_client

    expect_raises(ArgumentError, "pipeline failed") { client.pipelined { |_| } }

    client.stats.discarded.should eq 1
  end

  it "keeps the connection after a run that fails with such an error, which cannot desync it" do
    client = failing_client

    expect_raises(ArgumentError) { client.run { |_| raise ArgumentError.new("plain") } }

    client.stats.discarded.should eq 0
  end

  it "releases the pool once however many fibers close it at the same time" do
    releases = 0
    client = failing_client(-> { releases += 1; Fiber.yield; nil })
    done = ::Channel(Nil).new
    5.times { spawn { client.close; done.send(nil) } }
    5.times { done.receive }

    releases.should eq 1
  end
end

describe Azu::Redis::Pool do
  it "keeps a connection that was checked in after the failed attempt started" do
    with_fake_clock do |clock|
      created = [] of FakeConnection
      pool = fake_pool(3, created: created)
      old = [pool.checkout, pool.checkout]
      fresh = pool.checkout
      old.each { |connection| pool.checkin(connection) }
      clock.advance(1.second)
      attempt_started = clock.instant
      clock.advance(1.second)
      pool.checkin(fresh)

      pool.drop_idle(attempt_started)

      old.all?(&.closed?).should be_true
      fresh.closed?.should be_false
      pool.checkout.should be fresh
    end
  end

  it "closes a connection checked in at exactly the failed attempt's start, and keeps one checked in just after" do
    with_fake_clock do |clock|
      created = [] of FakeConnection
      pool = fake_pool(2, created: created)
      at_start = pool.checkout
      after = pool.checkout
      pool.checkin(at_start)
      attempt_started = clock.instant
      clock.advance(1.nanosecond)
      pool.checkin(after)

      pool.drop_idle(attempt_started)

      at_start.closed?.should be_true
      after.closed?.should be_false
    end
  end

  it "closes a connection checked in after the pool closed" do
    created = [] of FakeConnection
    pool = fake_pool(1, created: created)
    connection = pool.checkout
    pool.close

    pool.checkin(connection)

    connection.closed?.should be_true
    pool.stats.open.should eq 0
  end
end

describe "retry per consumer" do
  # Sleeping in the backoff advances the fake clock, so the clock tells whether a call retried.
  it "never retries a cache increment, retries a cache read" do
    with_fake_clock do |clock|
      store = Azu::Cache::RedisStore.new(UNREACHABLE)
      started = clock.instant

      store.increment("n").should be_nil
      clock.instant.should eq started

      store.get("k").should be_nil
      clock.instant.should be > started
      store.close
    end
  end

  it "retries a PubSub publish" do
    with_fake_clock do |clock|
      backend = Azu::PubSub::Redis.new(UNREACHABLE)
      started = clock.instant

      expect_raises(Redis::CannotConnectError) { backend.broadcast("t", "x") }

      clock.instant.should be > started
      backend.shutdown
    end
  end

  it "retries presence commands, transactions included" do
    with_fake_clock do |clock|
      store = Azu::Presence::Store::Redis.new(UNREACHABLE)
      started = clock.instant

      expect_raises(Redis::CannotConnectError) { store.renew("node", Time.utc) }
      after_command = clock.instant
      after_command.should be > started

      expect_raises(Redis::CannotConnectError) { store.evict("t", [Azu::Presence::Meta.new("ref", "node", "k", JSON::Any.new({} of String => JSON::Any), 0_i64)]) }
      clock.instant.should be > after_command
      store.shutdown
    end
  end
end

describe Azu::Redis do
  describe "after the server dropped every connection" do
    it "succeeds on one retry although several idle connections are dead" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 3))
      begin
        with_fake_clock do
          fill_pool(client)
          client.stats.open.should eq 3
          kill_all_clients

          client.run(retry: true, &.ping).should eq "PONG"
        end
      ensure
        client.close
      end
    end

    it "costs a call without retry one failure, not one per dead connection" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 3))
      begin
        fill_pool(client)
        kill_all_clients

        expect_raises(Redis::ConnectionError) { client.run(retry: false, &.ping) }
        client.run(retry: false, &.ping).should eq "PONG"
      ensure
        client.close
      end
    end
  end

  describe "a failed transaction or pipeline" do
    it "does not leave a stale reply for the next user of the pool" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 1))
      begin
        key = "azu:redis_spec:desync:#{Random::Secure.hex(4)}"
        expect_raises(Redis::Error) do
          client.pipelined do |pipeline|
            pipeline.command(["SET", key, "v"])
            pipeline.command(["NOSUCHCOMMAND"])
            pipeline.command(["GET", key])
          end
        end

        client.run(&.command(["ECHO", "fresh"])).should eq "fresh"
        client.stats.discarded.should eq 1
        client.run(&.del(key))
      ensure
        client.close
      end
    end

    it "does not leave the connection inside MULTI when the block raises" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 1))
      begin
        key = "azu:redis_spec:multi:#{Random::Secure.hex(4)}"
        expect_raises(ArgumentError) do
          client.multi do |transaction|
            transaction.command(["SET", key, "v"])
            raise ArgumentError.new("changed my mind")
          end
        end

        client.run(&.get(key)).should be_nil
        client.stats.discarded.should eq 1
      ensure
        client.close
      end
    end
  end

  describe ".retryable?" do
    it "retries lost and refused connections but not timeouts or server replies" do
      Azu::Redis.retryable?(Redis::ConnectionLostError.new("IO::Error: Connection reset by peer")).should be_true
      Azu::Redis.retryable?(Redis::CannotConnectError.new("IO::TimeoutError: connect timed out")).should be_true
      Azu::Redis.retryable?(IO::Error.new("closed")).should be_true
      Azu::Redis.retryable?(Redis::ConnectionLostError.new("IO::TimeoutError: Read timed out")).should be_false
      Azu::Redis.retryable?(Redis::Error.new("WRONGTYPE Operation against a key")).should be_false
      Azu::Redis.retryable?(Redis::PoolTimeoutError.new("no connection")).should be_false
    end

    it "discards the connection of a timeout, a lost connection and a TLS failure, not of a server reply" do
      Azu::Redis.connection_failure?(Redis::ConnectionLostError.new("IO::TimeoutError: Read timed out")).should be_true
      Azu::Redis.connection_failure?(OpenSSL::Error.new("tls")).should be_true
      Azu::Redis.connection_failure?(Redis::Error.new("ERR unknown command")).should be_false
    end
  end

  describe Azu::Redis::Client do
    it "builds without connecting" do
      client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE))

      client.stats.open.should eq 0
      client.closed?.should be_false
    end

    it "waits the backoff between attempts on Azu::Clock and gives up after the policy's retries" do
      with_fake_clock do |clock|
        policy = Azu::Redis::Retry.new(retries: 2, base: 10.milliseconds, max: 1.second, jitter: 0.0)
        client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE, retry: policy))
        started = clock.instant
        calls = 0

        expect_raises(Redis::CannotConnectError) { client.run(retry: true) { |redis| calls += 1; redis.ping } }

        (clock.instant - started).should eq 30.milliseconds
        calls.should eq 0
      end
    end

    it "does not retry unless asked to, and does not wait" do
      with_fake_clock do |clock|
        client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE))
        started = clock.instant

        expect_raises(Redis::CannotConnectError) { client.run(&.ping) }

        clock.instant.should eq started
      end
    end

    it "does not retry an error that is not about the connection" do
      live_redis do |client|
        calls = 0

        expect_raises(ArgumentError) do
          client.run do |_|
            calls += 1
            raise ArgumentError.new("bug")
          end
        end

        calls.should eq 1
        client.stats.discarded.should eq 0
      end
    end

    it "ping answers false instead of raising, and health_check wraps it" do
      client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE, retry: Azu::Redis::Retry.none))

      client.ping.should be_false
      client.health_check.call.should be_false
    end

    it "prefixes keys and shares the pool with a prefixed view" do
      client = Azu::Redis::Client.new(Azu::Redis::Config.new(prefix: "app:"))
      view = client.with_prefix("app:cache:")

      client.key("a").should eq "app:a"
      view.key("a").should eq "app:cache:a"
      view.close
      client.closed?.should be_false
      client.close
      view.closed?.should be_true
    end

    it "raises ClosedError once closed, and closing twice is harmless" do
      client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE))
      client.close
      client.close

      expect_raises(Azu::Redis::ClosedError) { client.run(&.ping) }
    end

    it "reports finished calls to Instrumentation.redis, with the error if there was one" do
      Azu::Instrumentation.isolate do
        seen = [] of Azu::Instrumentation::RedisCommand
        Azu::Instrumentation.on_redis { |command| seen << command }
        client = Azu::Redis::Client.new(Azu::Redis::Config.new(url: UNREACHABLE, name: "probe", retry: Azu::Redis::Retry.none))

        expect_raises(Redis::CannotConnectError) { client.run("ping", &.ping) }

        seen.size.should eq 1
        seen.first.operation.should eq "ping"
        seen.first.client.should eq "probe"
        seen.first.error.should_not be_nil
        seen.first.duration_ms.should be >= 0
      end
    end

    it "talks to a live server" do
      live_redis do |client|
        prefix = "azu:redis_spec:#{Random::Secure.hex(4)}:"
        client.run(&.set("#{prefix}a", "1"))
        client.run(&.get("#{prefix}a")).should eq "1"
        client.multi do |transaction|
          transaction.command(["SET", "#{prefix}b", "2"])
          transaction.command(["SET", "#{prefix}c", "3"])
        end
        client.pipelined do |pipeline|
          pipeline.command(["INCR", "#{prefix}n"])
          pipeline.command(["INCR", "#{prefix}n"])
        end
        client.run { |redis| redis.mget("#{prefix}b", "#{prefix}c", "#{prefix}n") }.should eq ["2", "3", "2"]
        client.run { |redis| redis.del("#{prefix}a", "#{prefix}b", "#{prefix}c", "#{prefix}n") }
        client.ping.should be_true
        client.health_check.call.should be_true
      end
    end

    it "reads the server clock" do
      live_redis do |client|
        (client.time - Time.utc).abs.should be < 5.seconds
      end
    end

    it "names its connections for CLIENT LIST" do
      live_redis do |client|
        client.run(&.command(["CLIENT", "GETNAME"])).should eq "azu-spec"
        client.dedicated.command(["CLIENT", "GETNAME"]).should eq "azu-spec-subscriber"
      end
    end

    it "replaces a connection the server closed, then carries on" do
      live_redis do |client|
        id = client.run(&.command(["CLIENT", "ID"])).as(Int64)
        killer = Redis.new(url: REDIS_UTIL_URL, reconnect: false)
        begin
          killer.command(["CLIENT", "KILL", "ID", id.to_s])
        ensure
          killer.close
        end

        client.run(retry: true, &.ping).should eq "PONG"
        client.run(&.command(["CLIENT", "ID"])).as(Int64).should_not eq id
        client.stats.discarded.should eq 1
      end
    end

    it "surfaces a lost connection when retry is off, and discards it" do
      live_redis do |client|
        id = client.run(&.command(["CLIENT", "ID"])).as(Int64)
        killer = Redis.new(url: REDIS_UTIL_URL, reconnect: false)
        begin
          killer.command(["CLIENT", "KILL", "ID", id.to_s])
        ensure
          killer.close
        end

        expect_raises(Redis::ConnectionError) { client.run(retry: false, &.ping) }
        client.stats.discarded.should eq 1
        client.run(&.ping).should eq "PONG"
      end
    end

    it "discards a connection whose command timed out and does not run the command twice" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(command_timeout: 100.milliseconds))
      calls = 0

      begin
        expect_raises(Redis::Error) do
          client.run do |redis|
            calls += 1
            redis.command(["BLPOP", "azu:redis_spec:never:#{Random::Secure.hex(4)}", "2"])
          end
        end

        calls.should eq 1
        client.stats.discarded.should eq 1
        client.run(&.ping).should eq "PONG"
      ensure
        client.close
      end
    end

    it "keeps a connection after a server error reply" do
      live_redis do |client|
        expect_raises(Redis::Error) { client.run(&.command(["NOSUCHCOMMAND"])) }

        client.stats.discarded.should eq 0
        client.run(&.ping).should eq "PONG"
      end
    end

    it "gives a dedicated connection that is not part of the pool" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 1, checkout_timeout: 100.milliseconds))
      begin
        held = client.run { |redis| redis }
        subscriber = client.dedicated
        client.stats.open.should eq 1
        client.stats.adopted.should eq 1

        subscriber.ping.should eq "PONG"
        client.run(&.ping).should eq "PONG"
        held.should_not be subscriber

        client.close
        expect_raises(Redis::Error) { subscriber.ping }
      ensure
        client.close
      end
    end

    it "keeps working for others while a dedicated connection blocks in a subscription" do
      pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
      client = Azu::Redis::Client.new(live_config(pool_size: 1))
      begin
        topic = "azu:redis_spec:sub:#{Random::Secure.hex(4)}"
        received = ::Channel(String).new(1)
        subscriber = client.dedicated
        spawn do
          subscriber.subscribe(topic) { |on| on.message { |_channel, message| received.send(message) } }
        rescue Redis::Error | IO::Error
        end
        wait_until { client.run(&.command(["PUBSUB", "NUMSUB", topic])).as(Array)[1] == 1 }.should be_true

        client.run(&.publish(topic, "hello"))

        select
        when message = received.receive
          message.should eq "hello"
        when timeout(2.seconds)
          fail "no message"
        end
        client.release(subscriber)
      ensure
        client.close
      end
    end
  end

  describe ".acquire" do
    it "hands out handles on one pool for equal settings and closes it with the last handle" do
      Azu::Redis.shutdown
      config = Azu::Redis::Config.new(url: UNREACHABLE)
      first = Azu::Redis.acquire(config)
      second = Azu::Redis.acquire(config.copy_with(prefix: "x:", name: "other"))
      Azu::Redis.shared_count.should eq 1

      first.close
      first.close
      second.closed?.should be_false
      Azu::Redis.shared_count.should eq 1

      second.close
      second.closed?.should be_true
      Azu::Redis.shared_count.should eq 0
    end

    it "keeps separate pools for different settings" do
      Azu::Redis.shutdown
      one = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE))
      two = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE, pool_size: 2))

      Azu::Redis.shared_count.should eq 2
      one.close
      two.closed?.should be_false
      two.close
    end

    it "opens a new pool after the last handle went away" do
      Azu::Redis.shutdown
      config = Azu::Redis::Config.new(url: UNREACHABLE)
      Azu::Redis.acquire(config).close

      again = Azu::Redis.acquire(config)

      again.closed?.should be_false
      again.close
    end

    it "closes every shared pool on shutdown" do
      Azu::Redis.shutdown
      client = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE))

      Azu::Redis.shutdown

      client.closed?.should be_true
      Azu::Redis.shared_count.should eq 0
      client.close
    end
  end

  describe "shutdown ordering" do
    it "stops presence, then pubsub, then closes the Redis pool they used" do
      Azu::Redis.shutdown
      client = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE))
      events = [] of String

      pubsub = RecordingPubSub.new(events, client)
      presence_store = RecordingPresenceStore.new(events, client)
      Azu::PubSub.backend = pubsub
      Azu::Presence.default = Azu::Presence::Tracker.new(store: presence_store)
      events.clear

      Azu.shutdown

      events.should eq ["presence: pool open", "pubsub: pool open"]
      client.closed?.should be_true
    end
  end
end

private class RecordingPubSub < Azu::PubSub::Memory
  def initialize(@events : Array(String), @client : Azu::Redis::Client)
    super()
  end

  def shutdown : Nil
    @events << "pubsub: pool #{@client.closed? ? "closed" : "open"}"
    super
  end
end

private class RecordingPresenceStore < Azu::Presence::Store::Memory
  def initialize(@events : Array(String), @client : Azu::Redis::Client)
    super()
  end

  def shutdown : Nil
    @events << "presence: pool #{@client.closed? ? "closed" : "open"}"
    super
  end
end

# Delays the confirmation of the pattern subscription, to prove that subscribe waits for it.
private class SlowConfirmPubSub < Azu::PubSub::Redis
  getter confirmed_at : Time::Instant? = nil

  private def confirm_listening : Nil
    sleep 300.milliseconds unless @confirmed_at
    super
    @confirmed_at ||= Time.instant
  end
end

describe "consumers of Azu::Redis" do
  it "does not return from subscribe before Redis confirmed it, for concurrent first subscribers too" do
    pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
    prefix = "azu:redis_spec:first:#{Random::Secure.hex(4)}:"
    receiver = SlowConfirmPubSub.new(REDIS_UTIL_URL, prefix)
    sender = Azu::PubSub::Redis.new(REDIS_UTIL_URL, prefix)
    begin
      returned = ::Channel(Time::Instant).new(2)
      received = ::Channel(String).new(2)
      2.times do
        spawn do
          receiver.subscribe("t") { |message| received.send(message.payload) }
          returned.send(Time.instant)
        end
      end

      2.times { returned.receive.should be >= (receiver.confirmed_at || Time.instant) }
      sender.broadcast("t", "immediately")
      2.times do
        select
        when payload = received.receive
          payload.should eq "immediately"
        when timeout(2.seconds)
          fail "the broadcast was lost"
        end
      end
    ensure
      receiver.shutdown
      sender.shutdown
    end
  end

  it "stops waiting after the listen timeout when Redis does not answer, and says so" do
    backend = Azu::PubSub::Redis.new(UNREACHABLE, "azu:redis_spec:down:", 100.milliseconds)
    begin
      started = Time.instant
      Log.capture("Azu::PubSub") do |logs|
        backend.subscribe("t") { |_| }
        (Time.instant - started).should be >= 90.milliseconds

        second = Time.instant
        backend.subscribe("t") { |_| }
        (Time.instant - second).should be < 90.milliseconds
        logs.check(:warn, /did not confirm/)
      end
    ensure
      backend.shutdown
    end
  end

  it "wakes a subscriber that waits when the backend shuts down" do
    backend = Azu::PubSub::Redis.new(UNREACHABLE, "azu:redis_spec:down2:", 5.seconds)
    done = ::Channel(Time::Span).new(1)
    spawn do
      started = Time.instant
      backend.subscribe("t") { |_| }
      done.send(Time.instant - started)
    end
    Fiber.yield
    backend.shutdown

    select
    when elapsed = done.receive
      elapsed.should be < 2.seconds
    when timeout(3.seconds)
      fail "subscribe kept waiting after shutdown"
    end
  end

  it "refuses to build a Redis cache that has no URL, instead of picking localhost" do
    previous = ENV["CACHE_REDIS_URL"]?
    begin
      ENV.delete("CACHE_REDIS_URL")
      config = Azu::Cache::Configuration.new
      config.store = "redis"
      config.redis_url.should be_nil

      expect_raises(ArgumentError, /CACHE_REDIS_URL/) { Azu::Cache::Manager.new(config) }

      config.redis_url = "redis://localhost:6379/0" # an explicit opt-in to localhost
      Azu::Cache::Manager.new(config).store.should be_a Azu::Cache::RedisStore
    ensure
      previous.try { |value| ENV["CACHE_REDIS_URL"] = value }
    end
  end

  it "clears only the keys under the cache's prefix, leaving the rest of the database alone" do
    pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
    probe = Redis.new(url: REDIS_UTIL_URL, reconnect: false)
    token = Random::Secure.hex(4)
    # The prefix holds glob characters: unescaped, "a*b[c" would also match the sibling "aXXb[c:...".
    prefix = "clr#{token}a*b[c"
    sibling = "clr#{token}aXXb[c:sibling"
    config = Azu::Cache::Configuration.new
    config.store = "redis"
    config.redis_url = REDIS_UTIL_URL
    config.key_prefix = prefix
    manager = Azu::Cache::Manager.new(config)
    created = [] of String
    begin
      700.times { |index| manager.set("k#{index}", "v") }
      manager.set("we[ird*", "v")
      {"other:#{token}", "#{prefix}x", sibling}.each { |key| probe.set(key, "keep") }
      created.concat({"other:#{token}", "#{prefix}x", sibling})

      manager.clear.should be_true

      probe.keys("#{prefix.gsub(/[\\*?\[\]]/) { |char| "\\#{char}" }}:*").should be_empty
      {"other:#{token}", "#{prefix}x", sibling}.each { |key| probe.get(key).should eq "keep" }
    ensure
      created.each { |key| probe.del(key) }
      probe.close
      manager.store.as(Azu::Cache::RedisStore).close
    end
  end

  it "empties a store with clear(all: true)" do
    manager = Azu::Cache::Manager.new(Azu::Cache::Configuration.new.tap { |config| config.store = "memory" })
    manager.set("a", "1")

    manager.clear(all: true).should be_true

    manager.get("a").should be_nil
  end

  it "fails the boot of a configuration that asks for a Redis cache without a URL, instead of disabling the cache" do
    previous = ENV["CACHE_REDIS_URL"]?
    begin
      ENV.delete("CACHE_REDIS_URL")
      configuration = Azu::Configuration.new
      configuration.cache_config.store = "redis"

      expect_raises(ArgumentError, /CACHE_REDIS_URL/) { configuration.cache }
    ensure
      previous.try { |value| ENV["CACHE_REDIS_URL"] = value }
    end
  end

  it "checks the cache configuration at prepare, without connecting" do
    previous = ENV["CACHE_REDIS_URL"]?
    begin
      ENV.delete("CACHE_REDIS_URL")
      configuration = Azu::Configuration.new
      configuration.cache_config.store = "redis"

      expect_raises(ArgumentError, /CACHE_REDIS_URL/) { configuration.prepare }

      configuration.cache_config.redis_url = UNREACHABLE
      configuration.prepare # no error, and nothing connected
    ensure
      previous.try { |value| ENV["CACHE_REDIS_URL"] = value }
    end
  end

  it "still falls back to a disabled cache when the Redis it was pointed at is down" do
    configuration = Azu::Configuration.new
    configuration.cache_config.store = "redis"
    configuration.cache_config.redis_url = UNREACHABLE
    configuration.cache_config.cache_connection_retries = 1

    with_fake_clock { configuration.cache.set("k", "v").should be_false }
  end

  it "never points the cache at REDIS_URL, whose database `clear` would flush" do
    previous = {ENV["REDIS_URL"]?, ENV["CACHE_REDIS_URL"]?}
    begin
      ENV["REDIS_URL"] = "redis://sessions.internal:6379/0"
      ENV.delete("CACHE_REDIS_URL")
      Azu::Cache::Configuration.new.redis_url.should be_nil

      ENV["CACHE_REDIS_URL"] = "redis://cache.internal:6379/1"
      Azu::Cache::Configuration.new.redis_url.should eq "redis://cache.internal:6379/1"
      Azu::PubSub::Redis.default_url.should eq "redis://sessions.internal:6379/0"
    ensure
      ENV.delete("REDIS_URL"); previous[0].try { |value| ENV["REDIS_URL"] = value }
      ENV.delete("CACHE_REDIS_URL"); previous[1].try { |value| ENV["CACHE_REDIS_URL"] = value }
    end
  end

  it "gives back the pool a store or backend acquired from a URL, and leaves a client you passed open" do
    Azu::Redis.shutdown
    store = Azu::Cache::RedisStore.new(UNREACHABLE)
    backend = Azu::PubSub::Redis.new(UNREACHABLE)
    presence = Azu::Presence::Store::Redis.new(UNREACHABLE)
    Azu::Redis.shared_count.should eq 2 # the cache's 2 s command timeout differs from the 5 s of the other two

    store.close
    backend.shutdown
    Azu::Redis.shared_count.should eq 1
    presence.shutdown
    Azu::Redis.shared_count.should eq 0

    client = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE))
    Azu::Cache::RedisStore.new(client).close
    Azu::PubSub::Redis.new(client).shutdown
    Azu::Presence::Store::Redis.new(client).shutdown
    client.closed?.should be_false
    client.close
  end

  it "answers a cache command against a dead server as a miss without waiting out the pool" do
    store = Azu::Cache::RedisStore.new(UNREACHABLE, timeout: 200.milliseconds, operation_timeout: 200.milliseconds)

    with_fake_clock do
      store.get("k").should be_nil
      store.increment("n").should be_nil
    end
    store.close
  end

  it "shares a client through cache_config.redis_client" do
    client = Azu::Redis.acquire(Azu::Redis::Config.new(url: UNREACHABLE))
    config = Azu::Cache::Configuration.new
    config.store = "redis"
    config.redis_client = client

    store = Azu::Cache::Manager.new(config).store

    store.should be_a Azu::Cache::RedisStore
    client.close
  end
end

describe "connections shared by cache, pubsub and presence" do
  it "keeps them on one pool and one listener" do
    pending!("Redis is not reachable on #{REDIS_UTIL_URL}") unless redis_util_available?
    Azu::Redis.shutdown
    url = REDIS_UTIL_URL.sub(%r{/\d+\z}, "") + "/13"
    prefix = "azu:redis_spec:#{Random::Secure.hex(4)}:"
    probe = Redis.new(url: url, reconnect: false)
    count = -> { probe.command(["CLIENT", "LIST"]).as(String).lines.count(&.includes?(" db=13 ")) - 1 }
    baseline = count.call

    shared = Azu::Redis.acquire(Azu::Redis::Config.new(url: url, name: "spec-shared"))
    cache = Azu::Cache::RedisStore.new(shared)
    pubsub = Azu::PubSub::Redis.new(shared, "#{prefix}ps:")
    store = Azu::Presence::Store::Redis.new(shared, "#{prefix}pr:")
    own_pubsub = Azu::PubSub::Redis.new(url, "#{prefix}own:")
    own_store = Azu::Presence::Store::Redis.new(url, "#{prefix}ownpr:")

    begin
      received = ::Channel(String).new(4)
      pubsub.subscribe("t") { |message| received.send(message.payload) }
      wait_until { probe.command(["PUBSUB", "NUMPAT"]).as(Int64) > 0 }.should be_true
      cache.set("#{prefix}k", "v")
      pubsub.broadcast("t", "x")
      received.receive.should eq "x"
      store.renew("node", Time.utc + 1.minute)
      own_pubsub.broadcast("t", "y")
      own_store.renew("node", Time.utc + 1.minute)

      # Shared: one pooled connection (everything ran one after the other) plus the listener. Built from the
      # same URL, the second pubsub/presence pair shares one more pool: one pooled connection each, no listener.
      (count.call - baseline).should be <= 3
      cache.get("#{prefix}k").should eq "v"
    ensure
      cache.delete("#{prefix}k")
      pubsub.shutdown
      own_pubsub.shutdown
      store.shutdown
      own_store.shutdown
      shared.close
      probe.close
    end
  end
end
