require "../../spec_helper"
require "../../../src/azu/dev/dev"
require "../../support/integration_helpers"
require "log/spec"

include IntegrationHelpers

private def request_through(handler : Azu::Handler::DevDashboard, path : String, method : String = "GET") : {String, Bool}
  next_handler, verify = create_next_handler(1)
  handler.next = next_handler
  context, io = create_context(method, path)
  handler.call(context)
  body = get_response_body(context, io)
  {body, body == "OK"}
end

describe Azu::Handler::DevDashboard do
  describe "environment gate" do
    it "serves the dashboard in development" do
      with_azu_env(Azu::Environment::Development) do
        body, passed = request_through(Azu::Handler::DevDashboard.new, "/dev-dashboard")
        passed.should be_false
        body.should contain "<!DOCTYPE html>"
      end
    end

    (Azu::Environment.values - [Azu::Environment::Development]).each do |env|
      it "passes the dashboard path through to the next handler in #{env.to_s.downcase}" do
        with_azu_env(env) do
          handler = Azu::Handler::DevDashboard.new
          body, passed = request_through(handler, "/dev-dashboard")
          passed.should be_true
          body.should_not contain "<!DOCTYPE html>"
        end
      end

      it "passes the SQL playground path through in #{env.to_s.downcase}" do
        with_azu_env(env) do
          _, passed = request_through(Azu::Handler::DevDashboard.new, "/dev-dashboard/sql", "POST")
          passed.should be_true
        end
      end

      it "passes a custom path through in #{env.to_s.downcase}" do
        with_azu_env(env) do
          _, passed = request_through(Azu::Handler::DevDashboard.new("/__dev"), "/__dev")
          passed.should be_true
        end
      end
    end

    it "judges the environment on every request, not once at construction" do
      handler = Azu::Handler::DevDashboard.new
      with_azu_env(Azu::Environment::Development) { request_through(handler, "/dev-dashboard")[1].should be_false }
      with_azu_env(Azu::Environment::Production) { request_through(handler, "/dev-dashboard")[1].should be_true }
    end

    it "follows the configuration of the app serving the request" do
      production = Azu::Configuration.new
      production.env = Azu::Environment::Production
      with_azu_env(Azu::Environment::Development) do
        handler = Azu::Handler::DevDashboard.new
        Azu.with_config(production) { request_through(handler, "/dev-dashboard")[1].should be_true }
      end
    end

    it "keeps the SQL playground's CSRF exemption for development only" do
      Azu::Handler::CSRF.exempt?("/gate-dev/sql").should be_false
      with_azu_env(Azu::Environment::Production) { Azu::Handler::DevDashboard.new("/gate-dev") }
      Azu::Handler::CSRF.exempt?("/gate-dev/sql").should be_false
      with_azu_env(Azu::Environment::Development) { Azu::Handler::DevDashboard.new("/gate-dev") }
      Azu::Handler::CSRF.exempt?("/gate-dev/sql").should be_true
    end
  end

  describe "construction outside development" do
    (Azu::Environment.values - [Azu::Environment::Development]).each do |env|
      it "logs one warning in #{env.to_s.downcase}" do
        logs = ::Log.capture("spec.dashboard_gate") do
          with_azu_env(env) { Azu::Handler::DevDashboard.new(log: ::Log.for("spec.dashboard_gate")) }
        end
        logs.check(:warn, /DevDashboard.*#{env.to_s.downcase}.*only serves in development/i)
        logs.empty
      end
    end

    it "logs nothing in development" do
      logs = ::Log.capture("spec.dashboard_gate") do
        with_azu_env(Azu::Environment::Development) { Azu::Handler::DevDashboard.new(log: ::Log.for("spec.dashboard_gate")) }
      end
      logs.empty
    end
  end
end

describe Azu::Handler::PerformanceMonitor do
  it "exposes no data over HTTP in any environment: every path reaches the next handler untouched" do
    Azu::Environment.values.each do |env|
      with_azu_env(env) do
        monitor = Azu::Handler::PerformanceMonitor.new
        next_handler, verify = create_next_handler(1)
        monitor.next = next_handler
        context, io = create_context("GET", "/performance")
        monitor.call(context)
        get_response_body(context, io).should eq "OK"
        verify.call
      end
    end
  end
end
