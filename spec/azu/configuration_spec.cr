require "../spec_helper"

describe Azu::Configuration do
  describe "default configuration" do
    it "sets default values" do
      config = Azu::Configuration.new

      config.port.should eq(4000)
      # config.port_reuse.should be_false
      config.host.should eq("0.0.0.0")
    end

    it "sets default SSL configuration" do
      config = Azu::Configuration.new

      config.ssl_cert.should eq("")
      config.ssl_key.should eq("")
      config.ssl_ca.should eq("")
      config.ssl_mode.should eq("none")
    end
  end

  describe "environment variable configuration" do
    it "reads port from environment" do
      ENV["PORT"] = "8080"
      config = Azu::Configuration.new

      config.port.should eq(8080)

      ENV.delete("PORT")
    end

    it "reads host from environment" do
      ENV["HOST"] = "127.0.0.1"
      config = Azu::Configuration.new

      config.host.should eq("127.0.0.1")

      ENV.delete("HOST")
    end

    it "reads environment from CRYSTAL_ENV" do
      ENV["CRYSTAL_ENV"] = "production"
      config = Azu::Configuration.new

      config.env.should eq(Azu::Environment::Production)

      ENV["CRYSTAL_ENV"] = "test"
    end

    it "reads port_reuse from environment" do
      ENV["PORT_REUSE"] = "false"
      config = Azu::Configuration.new

      config.port_reuse.should be_false

      ENV["PORT_REUSE"] = "false"
    end
  end

  describe "SSL configuration" do
    it "configures SSL context" do
      config = Azu::Configuration.new

      # Test that SSL properties can be set correctly
      config.ssl_cert = "test.crt"
      config.ssl_key = "test.key"
      config.ssl_ca = "ca.crt"
      config.ssl_mode = "verify_peer"

      # Verify the properties are set correctly
      config.ssl_cert.should eq("test.crt")
      config.ssl_key.should eq("test.key")
      config.ssl_ca.should eq("ca.crt")
      config.ssl_mode.should eq("verify_peer")

      # Note: We don't test config.tls here because it requires actual certificate files
      # That would be tested in integration tests with real certificates
    end

    it "detects when TLS is enabled" do
      config = Azu::Configuration.new
      config.tls?.should be_false

      config.ssl_cert = "test.crt"
      config.ssl_key = "test.key"
      config.tls?.should be_true
    end
  end

  describe "router configuration" do
    it "provides router instance" do
      config = Azu::Configuration.new

      config.router.should be_a(Azu::Router)
    end
  end

  describe "templates configuration" do
    it "provides templates instance" do
      config = Azu::Configuration.new

      config.templates.should be_a(Azu::Templates)
    end

    it "reads template paths from environment" do
      ENV["TEMPLATES_PATH"] = "/custom/templates"
      config = Azu::Configuration.new

      config.templates.path.should contain("/custom/templates")

      ENV.delete("TEMPLATES_PATH")
    end

    it "reads error template path from environment" do
      ENV["ERROR_TEMPLATE"] = "/custom/errors"
      config = Azu::Configuration.new

      config.templates.error_path.should eq("/custom/errors")

      ENV.delete("ERROR_TEMPLATE")
    end
  end

  describe "logging configuration" do
    it "provides log instance" do
      config = Azu::Configuration.new

      config.log.should be_a(Log)
    end
  end

  describe "template hot reload configuration" do
    it "defaults to true for development environment" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      ENV.delete("TEMPLATE_HOT_RELOAD") if ENV.has_key?("TEMPLATE_HOT_RELOAD")

      ENV["CRYSTAL_ENV"] = "development"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_true

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "defaults to true for test environment" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      ENV.delete("TEMPLATE_HOT_RELOAD") if ENV.has_key?("TEMPLATE_HOT_RELOAD")

      ENV["CRYSTAL_ENV"] = "test"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_true

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

        it "defaults to true for pipeline environment" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      ENV.delete("TEMPLATE_HOT_RELOAD") if ENV.has_key?("TEMPLATE_HOT_RELOAD")

      ENV["CRYSTAL_ENV"] = "pipeline"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_true

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "defaults to false for production environment" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      ENV.delete("TEMPLATE_HOT_RELOAD") if ENV.has_key?("TEMPLATE_HOT_RELOAD")

      ENV["CRYSTAL_ENV"] = "production"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_false

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "can be overridden via TEMPLATE_HOT_RELOAD environment variable" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      original_hot_reload = ENV["TEMPLATE_HOT_RELOAD"]?

      # Test override in production (normally false)
      ENV["CRYSTAL_ENV"] = "production"
      ENV["TEMPLATE_HOT_RELOAD"] = "true"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_true

      # Test override in development (normally true)
      ENV["CRYSTAL_ENV"] = "development"
      ENV["TEMPLATE_HOT_RELOAD"] = "false"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_false

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end

      if original_hot_reload
        ENV["TEMPLATE_HOT_RELOAD"] = original_hot_reload
      else
        ENV.delete("TEMPLATE_HOT_RELOAD")
      end
    end

    it "can be modified at runtime" do
      config = Azu::Configuration.new

      config.template_hot_reload = true
      config.template_hot_reload.should be_true

      config.template_hot_reload = false
      config.template_hot_reload.should be_false
    end

    it "passes hot reload setting to templates" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?
      original_hot_reload = ENV["TEMPLATE_HOT_RELOAD"]?

      # Test with hot reload enabled
      ENV["CRYSTAL_ENV"] = "development"
      ENV.delete("TEMPLATE_HOT_RELOAD") if ENV.has_key?("TEMPLATE_HOT_RELOAD")
      config = Azu::Configuration.new

      config.template_hot_reload.should be_true
      config.templates.@hot_reload_enabled.should be_true

      # Test with hot reload disabled via environment override
      ENV["TEMPLATE_HOT_RELOAD"] = "false"
      config = Azu::Configuration.new

      config.template_hot_reload.should be_false
      config.templates.@hot_reload_enabled.should be_false

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end

      if original_hot_reload
        ENV["TEMPLATE_HOT_RELOAD"] = original_hot_reload
      else
        ENV.delete("TEMPLATE_HOT_RELOAD")
      end
    end
  end
end
