require "../spec_helper"

# Races the in-flight accounting of `App` and the copy-on-write path cache. Fibers only run in
# parallel in a `-Dpreview_mt` build (CI has a job for it: `crystal spec -Dpreview_mt` with
# CRYSTAL_WORKERS=4); in an ordinary build the same examples run on one thread, interleaved at
# `Fiber.yield`, and still check the invariants.

private def parallel(count : Int32, &block : Int32 ->) : ::Channel(Nil)
  done = ::Channel(Nil).new(count)
  count.times do |index|
    spawn(same_thread: false) do
      block.call(index)
    ensure
      done.send(nil)
    end
  end
  done
end

private def wait_for(done : ::Channel(Nil), count : Int32, within : Time::Span = 20.seconds) : Nil
  deadline = Time.instant + within
  count.times do
    select
    when done.receive
    when timeout(Math.max(deadline - Time.instant, 0.seconds))
      fail "timed out: a fiber hung"
    end
  end
end

# One app is shut down while the workers keep asking it to track requests; then the next one is.
private class Round
  getter app = Azu::App.new
  getter drained = Atomic(Int32).new(0)
  getter late = Atomic(Int32).new(0)
  getter running = Atomic(Int32).new(0)
end

describe "App in-flight accounting under parallel fibers" do
  it "never admits a request after the drain returned, never hangs the drain and ends at zero" do
    round = Round.new
    holder = Atomic(Round).new(round)
    stop = Atomic(Int32).new(0)
    workers = 6
    done = parallel(workers) do |_|
      until stop.get == 1
        current = holder.get
        current.app.track do
          current.running.add(1)
          # A request that runs after the drain returned was admitted too late
          current.late.add(1) if current.drained.get == 1
          current.running.sub(1)
        end
        Fiber.yield
      end
    end

    20_000.times do
      round = Round.new
      holder.set(round)
      Fiber.yield
      round.app.begin_shutdown
      drained = round.app.drain(2.seconds)
      round.drained.set(1)
      Fiber.yield
      fail "the drain timed out with #{round.running.get} requests running" unless drained
      round.late.get.should eq 0
      round.running.get.should eq 0
      round.app.track { fail "admitted after shutdown" }.should be_false
    end

    stop.set(1)
    wait_for(done, workers)
  end
end

describe Azu::Router do
  it "fills the path cache from several fibers while others read it" do
    router = Azu::Router.new
    paths = Array.new(300) { |i| "/items/#{i}" }
    stop = Atomic(Int32).new(0)
    wrong = Atomic(Int32).new(0)

    writers = 4
    readers = 3
    done = parallel(writers + readers) do |index|
      if index < writers
        # every writer inserts all paths, in its own order, so inserts collide
        paths.size.times do |i|
          path = paths[(i * (index + 1) + index) % paths.size]
          router.path_cache.set("GET", path, "/get#{path}")
          Fiber.yield if i % 16 == 0
        end
      else
        until stop.get == 1
          paths.each do |path|
            found = router.path_cache.get("GET", path)
            wrong.add(1) unless found.nil? || found == "/get#{path}"
          end
          Fiber.yield
        end
      end
    end
    # the writers are the first `writers` fibers to report; the readers stop once all of them did
    writers.times { done.receive }
    stop.set(1)
    wait_for(done, readers)

    wrong.get.should eq 0
    router.path_cache.stats[:size].should eq 300
    paths.each { |path| router.path_cache.get("GET", path).should eq "/get#{path}" }
  end
end
