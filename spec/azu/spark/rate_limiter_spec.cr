require "../../spec_helper"

describe Azu::Spark::RateLimiter do
  it "allows a burst and then refuses until tokens are refilled" do
    with_fake_clock do |clock|
      limiter = Azu::Spark::RateLimiter.new(rate: 100.0, burst: 5)

      5.times { limiter.allow?.should be_true }
      limiter.allow?.should be_false

      clock.advance(30.milliseconds)
      limiter.allow?.should be_true
    end
  end

  it "never accumulates more than the burst" do
    with_fake_clock do |clock|
      limiter = Azu::Spark::RateLimiter.new(rate: 1000.0, burst: 3)
      clock.advance(20.milliseconds)

      allowed = 10.times.count { limiter.allow? }

      allowed.should eq 3
    end
  end
end
