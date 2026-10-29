require "spec"
require "../src/azu"

{% if flag?(:azu_parallel_spec) %}
  Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
{% end %}

ENV["CRYSTAL_ENV"] ||= "test"

# Runs the block with Azu::CONFIG.env switched, restoring it afterwards.
def with_azu_env(env : Azu::Environment, &)
  original = Azu::CONFIG.env
  Azu::CONFIG.env = env
  begin
    yield
  ensure
    Azu::CONFIG.env = original
  end
end

# Runs the block with Azu::Clock replaced by a fake that only moves on `advance`; use it instead of `sleep`
# when a spec waits for a TTL, window or lifetime to pass.
def with_fake_clock(&)
  fake = Azu::Clock::Fake.new
  Azu::Clock.use(fake) { yield fake }
end

# Polls until the block is truthy or the timeout passes; returns whether it became true.
# Use it instead of a fixed `sleep` when a spec waits for something asynchronous.
def wait_until(timeout : Time::Span = 5.seconds, &) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant > deadline
    sleep 5.milliseconds
  end
  true
end

# Simple dummy request type for specs
struct TestRequest
  include Azu::Request

  @name : String = ""
  @email : String = ""
  @age : Int32? = nil

  getter name, email, age

  def initialize(@name = "", @email = "", @age = nil)
  end
end
