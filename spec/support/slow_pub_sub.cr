# A PubSub backend whose subscribe takes a while, like a Redis backend waiting for its first confirmation.
# `confirmed_at` is set once a subscribe has finished; `fail_first` makes the first subscribe raise after the wait and
# `fail_always` every one; `on_subscribe` runs in the subscribing fiber before the wait.
class SlowPubSub < Azu::PubSub::Memory
  getter subscribe_calls = 0
  getter topics = [] of String
  getter confirmed_at : Time::Instant? = nil
  property? fail_first = false
  property? fail_always = false
  property on_subscribe : Proc(Nil)? = nil
  # Waits for the calls in order, then falls back to the default delay.
  property delays = [] of Time::Span

  def initialize(@delay : Time::Span = 150.milliseconds)
    super()
  end

  def subscribe(topic : String, &handler : Azu::PubSub::Message ->) : Azu::PubSub::Subscription
    @subscribe_calls += 1
    @topics << topic
    first = @subscribe_calls == 1
    on_subscribe.try(&.call)
    sleep(delays.shift? || @delay)
    raise "the backend failed" if fail_always? || (first && fail_first?)
    super(topic, &handler).tap { @confirmed_at = Time.instant }
  end
end

# Runs the block with a SlowPubSub installed, restoring the in-memory default afterwards.
def with_slow_pub_sub(delay : Time::Span = 150.milliseconds, &)
  backend = SlowPubSub.new(delay)
  Azu::PubSub.backend = backend
  begin
    yield backend
  ensure
    Azu::PubSub.shutdown
  end
end
