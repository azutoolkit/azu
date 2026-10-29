require "../spec_helper"

describe "fiber-owned request and application scopes" do
  it "restores nested state after exceptions and releases the completed request" do
    app = Azu::App.new
    original = Azu.current_config
    Azu.with_scope(app, app.config) do
      Azu::RequestContext.with("outer") do
        expect_raises(Exception, "probe") do
          Azu.with_scope(Azu::App.new, Azu::Configuration.new) do
            Azu::RequestContext.with("inner") { raise "probe" }
          end
        end
        Azu.current_app.should be app
        Azu.current_config.should be app.config
        Azu::RequestContext.current?.try(&.request_id).should eq "outer"
      end
    end
    Azu.current_app.should be_nil
    Azu.current_config.should be original
    Azu::RequestContext.current?.should be_nil

    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))
    expect_raises(Exception, "probe") do
      Azu::RequestContext.scope(context) { raise "probe" }
    end
    Azu::RequestContext.current?.should be_nil
  end

  it "invalidates configurations across suspended fibers without clearing their app" do
    ready = Channel(Nil).new
    resume = Channel(Nil).new
    result = Channel(Bool).new
    app = Azu::App.new
    spawn do
      Azu.with_scope(app, app.config) do
        ready.send(nil)
        resume.receive
        result.send(Azu.current_app.same?(app) && Azu.current_config.same?(Azu::CONFIG))
      end
    end
    ready.receive
    Azu.clear_fiber_configs
    resume.send(nil)
    result.receive.should be_true
  end

  it "keeps overlapping requests isolated across yields and scheduler threads" do
    done = Channel(Bool).new(64)
    64.times do |index|
      spawn(same_thread: false) do
        valid = true
        app = Azu::App.new
        id = index.to_s
        100.times do
          Azu.with_scope(app, app.config) do
            Azu::RequestContext.with(id) do
              Fiber.yield
              valid &&= Azu.current_app.same?(app) && Azu.current_config.same?(app.config)
              valid &&= Azu::RequestContext.current?.try(&.request_id) == id
            end
          end
          valid &&= Azu.current_app.nil? && Azu::RequestContext.current?.nil?
        end
        done.send(valid)
      end
    end
    64.times do
      select
      when valid = done.receive
        valid.should be_true
      when timeout(20.seconds)
        fail "request scope isolation stalled"
      end
    end
  end
end
