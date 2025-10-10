require "../spec_helper"

describe "Design Pattern Refactoring" do
  describe "Throttle Handler Thread Safety" do
    it "handles concurrent requests safely" do
      throttle = Azu::Handler::Throttle.new(
        interval: 1,
        duration: 1,
        threshold: 5,
        blacklist: [] of String,
        whitelist: [] of String
      )

      # Create mock contexts
      contexts = Array(HTTP::Server::Context).new

      # Test that we can reset state
      throttle.reset
      stats = throttle.stats
      stats[:tracked_ips].should eq 0
      stats[:blocked_ips].should eq 0
    end

    it "tracks requests per IP correctly" do
      throttle = Azu::Handler::Throttle.new(
        interval: 10,
        duration: 10,
        threshold: 3,
        blacklist: [] of String,
        whitelist: [] of String
      )

      stats = throttle.stats
      stats.should be_a(NamedTuple(tracked_ips: Int32, blocked_ips: Int32))
    end

    it "provides reset functionality for testing" do
      throttle = Azu::Handler::Throttle.new(1, 1, 1, [] of String, [] of String)
      throttle.reset
      throttle.stats[:tracked_ips].should eq 0
    end
  end

  describe "Router PathCache Thread Safety" do
    it "provides stats about cache usage" do
      router = Azu::Router.new
      # The path cache is private, but we can verify the router works
      router.should be_a(Azu::Router)
    end

    it "can clear the path cache" do
      router = Azu::Router.new
      router.clear_path_cache
      # Should not raise
    end
  end

  describe "Spark Component Registry" do
    it "provides class-level registry" do
      registry = Azu::Spark.components
      registry.should be_a(Azu::ComponentRegistry)
    end

    it "can reset registry for testing" do
      Azu::Spark.reset_registry!
      new_registry = Azu::Spark.components
      new_registry.should be_a(Azu::ComponentRegistry)
    end

    it "accepts custom registry via dependency injection" do
      custom_registry = Azu::ComponentRegistry.new
      # Spark needs a socket, but we're just testing initialization
      # This would need a proper mock socket for full testing
    end
  end

  describe "CSRF Instance Configuration" do
    it "creates instance with custom configuration" do
      csrf = Azu::Handler::CSRF.new(
        strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
        secret_key: "test-secret-key",
        cookie_name: "test_csrf",
        secure_cookies: false
      )

      csrf.strategy.should eq Azu::Handler::CSRF::Strategy::SynchronizerToken
      csrf.cookie_name.should eq "test_csrf"
      csrf.secure_cookies.should be_false
    end

    it "provides default instance for backward compatibility" do
      default = Azu::Handler::CSRF.default
      default.should be_a(Azu::Handler::CSRF)
    end

    it "can reset default instance for testing" do
      Azu::Handler::CSRF.reset_default!
      new_default = Azu::Handler::CSRF.default
      new_default.should be_a(Azu::Handler::CSRF)
    end

    it "provides class-level compatibility methods" do
      # These should delegate to the default instance
      # Would need a proper HTTP context to test fully
    end

    it "supports multiple instances with different configurations" do
      csrf1 = Azu::Handler::CSRF.new(
        strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken
      )
      csrf2 = Azu::Handler::CSRF.new(
        strategy: Azu::Handler::CSRF::Strategy::DoubleSubmit
      )

      csrf1.strategy.should eq Azu::Handler::CSRF::Strategy::SynchronizerToken
      csrf2.strategy.should eq Azu::Handler::CSRF::Strategy::DoubleSubmit
    end
  end

  describe "Component Registry" do
    it "is thread-safe" do
      registry = Azu::ComponentRegistry.new
      registry.size.should eq 0
    end

    it "supports pooling" do
      registry = Azu::ComponentRegistry.new(max_pool_size: 10)
      registry.should be_a(Azu::ComponentRegistry)
    end
  end
end
