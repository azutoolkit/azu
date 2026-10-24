# A PubSub backend whose subscribe takes a while, like a Redis backend waiting for its first confirmation.
class SlowPubSub < Azu::PubSub::Memory
  getter subscribe_calls = 0
  getter topics = [] of String

  def subscribe(topic : String, &handler : Azu::PubSub::Message ->) : Azu::PubSub::Subscription
    @subscribe_calls += 1
    @topics << topic
    sleep 100.milliseconds
    super(topic, &handler)
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
