require "file_utils"
require "../spec_helper"

# Races the in-flight accounting of `App`, the router's lookups and the entry names Static
# publishes. Fibers only run in
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

# Answers with the id it was routed with, or "new" for the static route
private struct Echo
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << (context.request.path_params["id"]? || "new")
  end
end

describe Azu::Router do
  it "finds routes from several fibers at once, each request with its own params" do
    router = Azu::Router.new
    router.get "/items/new", Echo.new
    router.get "/items/:id", Echo.new
    wrong = Atomic(Int32).new(0)

    workers = 6
    done = parallel(workers) do |index|
      # every worker asks for the same ids, in its own order, so lookups of one route overlap
      300.times do |i|
        id = i % 50 == 0 ? "new" : ((i * (index + 1) + index) % 300).to_s
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        router.process(HTTP::Server::Context.new(HTTP::Request.new("GET", "/items/#{id}"), response))
        response.close
        wrong.add(1) unless io.to_s.partition("\r\n\r\n")[2] == id
        Fiber.yield if i % 16 == 0
      end
    end
    wait_for(done, workers)

    wrong.get.should eq 0
  end
end

# Counts the requests Static passed on, from every fiber.
private class CountingNext
  include HTTP::Handler

  getter passed = Atomic(Int32).new(0)

  def call(context : HTTP::Server::Context)
    @passed.add(1)
  end
end

describe Azu::Handler::Static do
  # A nilable reference in an Atomic is stored and loaded as one word; a `Set?` instance variable was two stores (type
  # id, then pointer), and a reader in between crashed on a null set. This check is what pins the publication.
  it "publishes the entry names through an Atomic" do
    typeof(Azu::Handler::Static.new("/azu-mt-no-such-dir").@entries).to_s.should start_with("Atomic(")
  end

  # A smoke test only: it never reproduced the torn read above against the old code (0 failures in several runs),
  # which takes millions of nil-to-set stores with readers in a tight loop, more than requests can drive here.
  it "publishes the entry names it reads whole while other fibers look them up" do
    dir = File.tempname("azu_mt_static")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "robots.txt"), "robots")
    with_fake_clock do |clock|
      counter = CountingNext.new
      fresh = -> { Azu::Handler::Static.new(dir).tap { |static| static.next = counter } }
      holder = Atomic(Azu::Handler::Static).new(fresh.call)
      stop = Atomic(Int32).new(0)
      calls = Atomic(Int32).new(0)
      readers = 4
      done = parallel(readers) do |_|
        # A path that names no entry: every lookup reads the names a fresh handler is publishing
        context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/plaintext"), HTTP::Server::Response.new(IO::Memory.new))
        until stop.get == 1
          holder.get.call(context)
          Fiber.yield if calls.add(1) % 64 == 0
        end
      end

      10_000.times do
        holder.set(fresh.call)
        clock.advance(Azu::Handler::Static::ENTRIES_RECHECK + 1.millisecond)
        Fiber.yield
      end
      stop.set(1)
      wait_for(done, readers)

      counter.passed.get.should eq calls.get
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe Azu::Templates do
  it "loads templates the compiled map does not hold from several fibers at once" do
    dir = File.tempname("azu_mt_templates")
    Dir.mkdir_p(dir)
    # `.txt` is not compiled at boot, so each first render parses it and stores it in Crinja's template cache. Without
    # the lock on that cache this crashes, raises from a corrupted Hash, or wedges the process (spinning at 100% CPU,
    # ignoring SIGTERM): CI then hangs until the job times out instead of failing fast.
    count = 400
    count.times { |i| File.write(File.join(dir, "t#{i}.txt"), "{{ v }}-#{i}") }
    wrong = Atomic(Int32).new(0)
    begin
      5.times do
        config = Azu::Configuration.new
        config.template_hot_reload = false
        config.templates.path = dir
        templates = config.templates
        done = parallel(count) do |i|
          # A render that raises counts as wrong: it would otherwise only end its fiber
          output = begin
            templates.render("t#{i}.txt", {"v" => "x"})
          rescue
            nil
          end
          wrong.add(1) unless output == "x-#{i}"
        end
        wait_for(done, count)
      end
    ensure
      FileUtils.rm_rf(dir)
    end

    wrong.get.should eq 0
  end
end
