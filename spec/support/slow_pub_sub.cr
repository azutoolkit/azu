# A PubSub backend whose subscribe takes a while, like a Redis backend waiting for its first confirmation.
# `confirmed_at` is set once a subscribe has finished; `fail_first` makes the first subscribe raise after the wait.
class SlowPubSub < Azu::PubSub::Memory
  getter subscribe_calls = 0
  getter topics = [] of String
  getter confirmed_at : Time::Instant? = nil
  property? fail_first = false

  def initialize(@delay : Time::Span = 150.milliseconds)
    super()
  end

  def subscribe(topic : String, &handler : Azu::PubSub::Message ->) : Azu::PubSub::Subscription
    @subscribe_calls += 1
    @topics << topic
    first = @subscribe_calls == 1
    sleep @delay
    raise "the backend failed" if first && fail_first?
    super(topic, &handler).tap { @confirmed_at = Time.instant }
  end
end

# Runs the block with a SlowPubSub installed, restoring the in-memory default afterwards.
def with_slow_pub_sub(&)
  backend = SlowPubSub.new
  Azu::PubSub.backend = backend
  begin
    yield backend
  ensure
    Azu::PubSub.shutdown
  end
end
