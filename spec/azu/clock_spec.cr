require "../spec_helper"

describe Azu::Clock do
  it "reads the system clock by default" do
    (Azu::Clock.now - Time.utc).abs.should be < 1.second
    (Azu::Clock.instant - Time.instant).abs.should be < 1.second
  end

  it "stands still until the fake is advanced, for both wall time and instants" do
    with_fake_clock do |clock|
      start, mark = Azu::Clock.now, Azu::Clock.instant
      Azu::Clock.now.should eq start

      clock.advance(90.seconds)

      Azu::Clock.now.should eq start + 90.seconds
      (Azu::Clock.instant - mark).should eq 90.seconds
    end
  end

  it "reads coarse nanoseconds that move with instant, to within a timer tick" do
    coarse, fine = Azu::Clock.coarse_nanoseconds, Azu::Clock.instant
    until Azu::Clock.instant - fine >= 30.milliseconds
      Azu::Clock.coarse_nanoseconds.should be >= coarse
    end
    coarse_elapsed = (Azu::Clock.coarse_nanoseconds - coarse).nanoseconds

    # A tick is 1-10 ms (CONFIG_HZ 1000 to 100); the bound leaves room for a loaded runner
    (coarse_elapsed - (Azu::Clock.instant - fine)).abs.should be < 50.milliseconds
  end

  it "moves a fake's coarse nanoseconds with its instant" do
    with_fake_clock do |clock|
      mark = Azu::Clock.coarse_nanoseconds
      clock.advance(90.seconds)
      (Azu::Clock.coarse_nanoseconds - mark).should eq 90.seconds.total_nanoseconds.to_i64
    end
  end

  it "restores the previous source after the block, even when it raises" do
    original = Azu::Clock.source
    expect_raises(Exception, "boom") { Azu::Clock.use(Azu::Clock::Fake.new) { raise "boom" } }
    Azu::Clock.source.should be original
  end
end

describe Azu::Clock::Fake do
  it "steps the wall clock without moving instants" do
    with_fake_clock do |clock|
      start, mark = Azu::Clock.now, Azu::Clock.instant
      clock.step_wall_clock(1.hour)
      Azu::Clock.now.should eq start + 1.hour
      Azu::Clock.instant.should eq mark
    end
  end
end
