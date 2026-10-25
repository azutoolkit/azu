require "../spec_helper"
require "log/spec"

private def with_process_env(vars : Hash(String, String?), &)
  saved = vars.keys.map { |name| {name, ENV[name]?} }
  vars.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  begin
    yield
  ensure
    saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  end
end

describe "the default bind host" do
  it "is loopback in development when no host was configured" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "development"}) do
      Azu::Configuration.new.host.should eq "127.0.0.1"
    end
  end

  it "is loopback when CRYSTAL_ENV is unset, which means development" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => nil}) do
      config = Azu::Configuration.new
      config.env.should eq Azu::Environment::Development
      config.host.should eq "127.0.0.1"
    end
  end

  it "stays 0.0.0.0 in every other environment" do
    with_process_env({"HOST" => nil}) do
      (Azu::Environment.values - [Azu::Environment::Development]).each do |env|
        config = Azu::Configuration.new
        config.env = env
        config.host.should eq "0.0.0.0"
      end
    end
  end

  it "follows the environment the configuration has when it is read" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "development"}) do
      config = Azu::Configuration.new
      config.env = Azu::Environment::Production
      config.host.should eq "0.0.0.0"
      config.env = Azu::Environment::Development
      config.host.should eq "127.0.0.1"
    end
  end

  it "keeps a host set on the configuration, 0.0.0.0 included" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "development"}) do
      config = Azu::Configuration.new
      config.host = "0.0.0.0"
      config.host.should eq "0.0.0.0"
    end
  end

  it "keeps a host given by HOST, 0.0.0.0 included" do
    with_process_env({"HOST" => "0.0.0.0", "CRYSTAL_ENV" => "development"}) do
      Azu::Configuration.new.host.should eq "0.0.0.0"
    end
  end

  it "treats a blank HOST as not set" do
    with_process_env({"HOST" => "  ", "CRYSTAL_ENV" => "development"}) do
      Azu::Configuration.new.host.should eq "127.0.0.1"
    end
  end
end

describe "an environment taken from the default" do
  it "is known to the configuration" do
    with_process_env({"CRYSTAL_ENV" => nil}) do
      Azu::Configuration.new.env_from_default?.should be_true
    end
    with_process_env({"CRYSTAL_ENV" => "development"}) do
      Azu::Configuration.new.env_from_default?.should be_false
    end
  end

  it "is no longer the default once the app sets it" do
    with_process_env({"CRYSTAL_ENV" => nil}) do
      config = Azu::Configuration.new
      config.env = Azu::Environment::Development
      config.env_from_default?.should be_false
    end
  end

  it "is announced with one INFO line naming the address" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => nil}) do
      config = Azu::Configuration.new
      config.log = ::Log.for("spec.default_host")
      config.container = false
      logs = ::Log.capture("spec.default_host") do
        config.announce_default_environment
      end
      logs.check(:info, "CRYSTAL_ENV not set, running in development, listening on 127.0.0.1")
      logs.empty
    end
  end

  it "is not announced when CRYSTAL_ENV was set, or the app chose the environment" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "development"}) do
      config = Azu::Configuration.new
      config.log = ::Log.for("spec.default_host")
      logs = ::Log.capture("spec.default_host") { config.announce_default_environment }
      logs.empty
    end
  end
end

# Yields what `warn_about_bind_host` logged for a configuration built under the given process environment.
private def logged(env : String?, host : String?, container : Bool, &)
  with_process_env({"HOST" => host, "CRYSTAL_ENV" => env}) do
    config = Azu::Configuration.new
    config.container = container
    config.log = ::Log.for("spec.bind_host")
    logs = ::Log.capture("spec.bind_host") { config.warn_about_bind_host }
    yield logs
  end
end

describe "the bind host warnings" do
  it "treats an empty host like no host" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "development"}) do
      config = Azu::Configuration.new
      config.host = ""
      config.host.should eq "127.0.0.1"
      config.host = "0.0.0.0"
      config.host = ""
      config.host.should eq "127.0.0.1"
    end
  end

  it "warns, naming HOST=0.0.0.0, when the development default is loopback inside a container" do
    logged(nil, nil, true) do |logs|
      logs.check(:warn, /listening on 127\.0\.0\.1 \(the development default\) inside a container.*Set HOST=0\.0\.0\.0/)
      logs.empty
    end
    logged("development", nil, true) do |logs|
      logs.check(:warn, /the development default.*HOST=0\.0\.0\.0/)
      logs.empty
    end
  end

  it "warns for an explicit loopback host in a container too" do
    logged("production", "127.0.0.1", true) do |logs|
      logs.check(:warn, /the configured host.*HOST=0\.0\.0\.0/)
      logs.empty
    end
  end

  it "is quiet outside a container, or when the container host is open" do
    logged("development", nil, false, &.empty)
    logged("development", "0.0.0.0", true, &.empty)
    logged("production", nil, true, &.empty)
  end

  it "warns that debug pages are on every interface when CRYSTAL_ENV was never set and the host is not loopback" do
    logged(nil, "0.0.0.0", false) do |logs|
      logs.check(:warn, /CRYSTAL_ENV is not set.*every interface/)
      logs.empty
    end
    logged("development", "0.0.0.0", false, &.empty)
  end
end

describe "the configured host" do
  it "tells a host that was set from the environment's default" do
    with_process_env({"HOST" => nil, "CRYSTAL_ENV" => "production"}) do
      config = Azu::Configuration.new
      config.host.should eq "0.0.0.0"
      config.configured_host.should be_nil # the default is not a setting
      config.host = "0.0.0.0"
      config.configured_host.should eq "0.0.0.0"
      config.host = nil
      config.configured_host.should be_nil
    end
  end
end
