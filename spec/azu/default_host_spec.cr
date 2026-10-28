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

# Yields what `check_bind_host` logged for a configuration built under the given process environment.
private def logged(env : String?, host : String?, container : Bool, allow_dev : String? = nil, &)
  with_process_env({"HOST" => host, "CRYSTAL_ENV" => env, "AZU_ALLOW_DEV_ON_ANY_HOST" => allow_dev}) do
    config = Azu::Configuration.new
    config.container = container
    config.log = ::Log.for("spec.bind_host")
    logs = ::Log.capture("spec.bind_host") { config.check_bind_host }
    yield logs
  end
end

describe "the container and loopback detection" do
  it "recognises Docker, Podman and Kubernetes" do
    with_process_env({"KUBERNETES_SERVICE_HOST" => nil}) do
      File.tempfile("containerenv") do |marker|
        Azu::Configuration.container_detected?(["/nonexistent/.dockerenv"]).should be_false
        Azu::Configuration.container_detected?(["/nonexistent/.dockerenv", marker.path]).should be_true
      end
    end
    with_process_env({"KUBERNETES_SERVICE_HOST" => "10.0.0.1"}) do
      Azu::Configuration.container_detected?(["/nonexistent/.dockerenv"]).should be_true
    end
    Azu::Configuration::CONTAINER_MARKERS.should contain "/run/.containerenv" # Podman
  end

  it "takes the bracketed IPv6 loopback for loopback" do
    config = Azu::Configuration.new
    {"127.0.0.1", "localhost", "::1", "[::1]"}.each do |address|
      config.host = address
      config.loopback_host?.should be_true
    end
    {"0.0.0.0", "::", "[::]", "10.0.0.5"}.each do |address|
      config.host = address
      config.loopback_host?.should be_false
    end
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

  it "refuses to serve the debug pages on every interface when CRYSTAL_ENV was never set and the host is not loopback" do
    with_process_env({"HOST" => "0.0.0.0", "CRYSTAL_ENV" => nil, "AZU_ALLOW_DEV_ON_ANY_HOST" => nil}) do
      config = Azu::Configuration.new
      config.container = false
      error = expect_raises(Azu::Configuration::BootError, /CRYSTAL_ENV is not set.*every interface/) { config.check_bind_host }
      error.message.to_s.should contain "AZU_ALLOW_DEV_ON_ANY_HOST=true"
      expect_raises(Azu::Configuration::BootError) { config.check_boot }
    end
    logged("development", "0.0.0.0", false, &.empty)
  end

  it "serves them with a warning when AZU_ALLOW_DEV_ON_ANY_HOST is set" do
    logged(nil, "0.0.0.0", false, "true") do |logs|
      logs.check(:warn, /CRYSTAL_ENV is not set.*every interface.*AZU_ALLOW_DEV_ON_ANY_HOST is set/)
      logs.empty
    end
  end
end

describe "the TLS files check" do
  it "refuses one of SSL_CERT and SSL_KEY without the other, and accepts both or neither" do
    with_process_env({"CRYSTAL_ENV" => "test"}) do
      config = Azu::Configuration.new
      config.ssl_cert = "/etc/azu/cert.pem"
      config.ssl_key = ""
      expect_raises(Azu::Configuration::BootError, /SSL_CERT is set but SSL_KEY is not/) { config.check_tls_files }
      config.ssl_cert = ""
      config.ssl_key = "/etc/azu/key.pem"
      expect_raises(Azu::Configuration::BootError, /SSL_KEY is set but SSL_CERT is not/) { config.check_tls_files }
      config.ssl_cert = "/etc/azu/cert.pem"
      config.check_tls_files
      config.ssl_cert = ""
      config.ssl_key = ""
      config.check_tls_files
    end
  end
end

describe "the WebSocket limits check" do
  it "refuses a subscription cap below one and an idle timeout the heartbeat cannot judge" do
    config = Azu::Configuration.new
    config.websocket.max_subscriptions = 0
    expect_raises(Azu::Configuration::BootError, /max_subscriptions/) { config.check_websocket_limits }
    config.websocket.max_subscriptions = 64
    config.websocket.ping_interval = 60.seconds
    config.websocket.idle_timeout = 90.seconds
    expect_raises(Azu::Configuration::BootError, /twice websocket.ping_interval/) { config.check_websocket_limits }
    config.websocket.idle_timeout = 120.seconds
    config.check_websocket_limits
    config.websocket.ping_interval = nil
    config.check_websocket_limits
  end
end

describe "the trusted proxies" do
  it "are parsed when set, answer a copy, and refuse an entry that is not an address or a catch-all block" do
    config = Azu::Configuration.new
    config.trusted_proxies = ["10.0.0.0/8", "::1"]
    config.trusted_proxy_networks.includes?(Azu::Handler::ClientAddress.parse("10.1.2.3").not_nil!).should be_true
    config.trusted_proxies << "192.0.2.1" # a copy: the setting is unchanged
    config.trusted_proxies.should eq ["10.0.0.0/8", "::1"]
    expect_raises(ArgumentError, /trusted_proxies/) { config.trusted_proxies = ["not-an-address"] }
    expect_raises(ArgumentError) { config.trusted_proxies = ["0.0.0.0/0"] }
    config.trusted_proxies.should eq ["10.0.0.0/8", "::1"] # a refused list changes nothing
  end
end

describe "the boot checks" do
  it "fail on a missing variable registered for boot in a strict environment, with nothing bound" do
    Azu::Env.reset_required_at_boot!
    Azu::Env.require_at_boot("AZU_BOOT_SPEC_SECRET")
    begin
      with_process_env({"AZU_BOOT_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "test"}) do
        config = Azu::Configuration.new
        config.env = Azu::Environment::Production
        config.strict_environment?.should be_true
        expect_raises(Azu::Env::MissingError, /AZU_BOOT_SPEC_SECRET is not set/) { config.check_boot }

        app = Azu::App.new(config)
        app.config.host = "127.0.0.1"
        app.config.port = 0
        handlers = [Azu::Handler::RequestId.new] of HTTP::Handler
        expect_raises(Azu::Env::MissingError) { app.start(handlers, teardown: false, signals: false) }
        app.address.should be_nil
        handlers.first.next.should be_nil # nothing was chained or bound: the same handlers can start the app once the variable is set

        with_process_env({"AZU_BOOT_SPEC_SECRET" => "set now"}) do
          finished = ::Channel(Nil).new
          spawn(name: "boot-spec-retry") do
            app.start(handlers, teardown: false, signals: false)
          ensure
            finished.send(nil)
          end
          wait_until { app.address }.should be_true
          app.stop(2.seconds)
          finished.receive
        end
      end
    ensure
      Azu::Env.reset_required_at_boot!
    end
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
