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
