require "../spec_helper"

# A wait that fails the example instead of hanging the run when something regresses.
private def within(span : Time::Span = 5.seconds, &block : -> T) : T forall T
  done = ::Channel(T).new(1)
  spawn { done.send(block.call) }
  select
  when value = done.receive
    value
  when timeout(span)
    fail "timed out"
  end
end

# These guard the in-flight accounting of `App#track` (two atomic operations per request) and the
# fiber registry behind `Azu.with_scope`. They hold with and without `-Dpreview_mt`.
describe Azu::App do
  describe "#track" do
    it "runs the block and answers true" do
      app = Azu::App.new
      ran = false

      app.track { ran = true }.should be_true
      ran.should be_true
      app.drain(10.milliseconds).should be_true
    end

    it "does not run the block once the app is shutting down" do
      app = Azu::App.new
      app.begin_shutdown
      ran = false

      app.track { ran = true }.should be_false
      ran.should be_false
      app.drain(10.milliseconds).should be_true
    end

    it "leaves when the block raises, so a drain does not wait for a request that failed" do
      app = Azu::App.new

      expect_raises(Exception, "boom") { app.track { raise "boom" } }
      app.begin_shutdown
      app.drain(10.milliseconds).should be_true
    end

    it "counts every request of many concurrent fibers and wakes the drain after the last one" do
      app = Azu::App.new
      gate = ::Channel(Nil).new
      finished = ::Channel(Nil).new(200)
      200.times do
        spawn do
          app.track { gate.receive? }
          finished.send(nil)
        end
      end
      Fiber.yield
      app.begin_shutdown
      app.drain(20.milliseconds).should be_false

      drained = ::Channel(Bool).new(1)
      spawn { drained.send(app.drain(5.seconds)) }
      Fiber.yield
      gate.close
      200.times { within { finished.receive } }

      within { drained.receive }.should be_true
    end

    it "wakes every drain that waits, and a drain that timed out does not leave one behind" do
      app = Azu::App.new
      gate = ::Channel(Nil).new
      entered = ::Channel(Nil).new(1)
      spawn { app.track { entered.send(nil); gate.receive } }
      within { entered.receive }

      app.drain(10.milliseconds).should be_false

      first = ::Channel(Bool).new(1)
      second = ::Channel(Bool).new(1)
      spawn { first.send(app.drain(5.seconds)) }
      spawn { second.send(app.drain(5.seconds)) }
      Fiber.yield
      gate.send(nil)

      within { first.receive }.should be_true
      within { second.receive }.should be_true
      app.drain(10.milliseconds).should be_true
    end

    it "refuses a request that arrives while a drain waits and still wakes the drain" do
      app = Azu::App.new
      gate = ::Channel(Nil).new
      entered = ::Channel(Nil).new(1)
      spawn { app.track { entered.send(nil); gate.receive } }
      within { entered.receive }
      app.begin_shutdown

      drained = ::Channel(Bool).new(1)
      spawn { drained.send(app.drain(5.seconds)) }
      Fiber.yield
      app.track { fail "ran during shutdown" }.should be_false
      gate.send(nil)

      within { drained.receive }.should be_true
    end
  end
end

describe "Azu.with_scope" do
  it "makes the app and its configuration current, and restores both afterwards" do
    app = Azu::App.new

    Azu.with_scope(app, app.config) do
      Azu.current_app.should be app
      Azu.current_config.should be app.config
    end
    Azu.current_app.should be_nil
    Azu.current_config.should be Azu::CONFIG
  end

  it "restores the outer scope when nested and when the block raises" do
    outer = Azu::App.new
    inner = Azu::App.new

    Azu.with_scope(outer, outer.config) do
      expect_raises(Exception, "boom") do
        Azu.with_scope(inner, inner.config) do
          Azu.current_app.should be inner
          raise "boom"
        end
      end
      Azu.current_app.should be outer
      Azu.current_config.should be outer.config
    end
    Azu.current_app.should be_nil
  end

  it "keeps the app when only a configuration is nested, and the configuration when only an app is" do
    app = Azu::App.new
    other_config = Azu::Configuration.new
    other_app = Azu::App.new

    Azu.with_scope(app, app.config) do
      Azu.with_config(other_config) do
        Azu.current_app.should be app
        Azu.current_config.should be other_config
      end
      Azu.current_config.should be app.config

      Azu.with_app(other_app) do
        Azu.current_app.should be other_app
        Azu.current_config.should be app.config
      end
      Azu.current_app.should be app
    end
  end

  it "leaves the app alone for a nil app, as with_app does" do
    app = Azu::App.new
    config = Azu::Configuration.new

    Azu.with_app(app) do
      Azu.with_scope(nil, config) do
        Azu.current_app.should be app
        Azu.current_config.should be config
      end
      Azu.current_config.should be Azu::CONFIG
    end
  end

  it "keeps the scopes of concurrent fibers apart" do
    apps = Array.new(20) { Azu::App.new }
    results = ::Channel(Bool).new(20)
    apps.each do |app|
      spawn do
        Azu.with_scope(app, app.config) do
          Fiber.yield
          results.send(Azu.current_app.same?(app) && Azu.current_config.same?(app.config))
        end
      end
    end

    20.times { within { results.receive }.should be_true }
    Azu.current_app.should be_nil
  end

  it "clears fiber configurations but not the app of the scope" do
    app = Azu::App.new

    Azu.with_scope(app, app.config) do
      Azu.clear_fiber_configs
      Azu.current_app.should be app
      Azu.current_config.should be Azu::CONFIG
    end
  end
end
