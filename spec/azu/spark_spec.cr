require "../spec_helper"
require "../support/spark_helpers"

module SparkModuleSpec
  class Hello < Azu::Spark::Component
    mountable

    prop name : String = "world"

    def render
      span "hello #{name}"
    end
  end
end

describe Azu::Spark do
  describe ".install" do
    it "registers the WebSocket endpoint at the configured path" do
      router = Azu::Router.new
      Azu::Spark.install(router)

      routes = router.route_info
      socket = routes.select { |route| route["method"] == "WEBSOCKET" }
      socket.size.should eq 1
      socket.first["path"].should eq "/spark"
      socket.first["handler"].should eq "Azu::Spark::Connection"
      routes.select { |route| route["path"] == Azu::Spark.config.assets_path }.map { |route| route["handler"] }.uniq!.should eq ["Azu::Spark::Client::Asset"]
    end

    # A production app without SPARK_SECRET must not boot and fail on its first live page instead.
    it "refuses to install without a secret in production and staging, before registering a route" do
      previous = Azu::Spark.config.secret
      Azu::Spark.config.secret = nil
      begin
        [Azu::Environment::Production, Azu::Environment::Staging].each do |env|
          router = Azu::Router.new
          with_azu_env(env) do
            expect_raises(Azu::Spark::ConfigurationError, /signing secret/) { Azu::Spark.install(router) }
          end
          router.route_info.should be_empty
        end
      ensure
        Azu::Spark.config.secret = previous
      end
    end

    it "installs in production with a secret" do
      previous = Azu::Spark.config.secret
      Azu::Spark.config.secret = "a production secret"
      router = Azu::Router.new
      begin
        with_azu_env(Azu::Environment::Production) { Azu::Spark.install(router) }
      ensure
        Azu::Spark.config.secret = previous
      end

      router.route_info.any? { |route| route["method"] == "WEBSOCKET" }.should be_true
    end
  end

  describe ".render" do
    it "renders the view with its identity, a join token and escaped props" do
      html = Azu::Spark.render(SparkModuleSpec::Hello, name: "<b>Ada</b>")

      html.should contain "data-spark-view='SparkModuleSpec::Hello'"
      html.should contain "data-spark-root"
      html.should contain "hello &lt;b&gt;Ada&lt;/b&gt;"
      html.should_not contain "<b>Ada</b>"
    end

    it "gives every render its own id and token" do
      first = Azu::Spark.render(SparkModuleSpec::Hello)
      second = Azu::Spark.render(SparkModuleSpec::Hello)

      first.match!(/data-spark-id='([^']+)'/)[1].should_not eq second.match!(/data-spark-id='([^']+)'/)[1]
      first.match!(/data-spark-token='([^']+)'/)[1].should_not eq second.match!(/data-spark-token='([^']+)'/)[1]
    end

    it "does not open a connection" do
      before = Azu::Spark.connection_count

      Azu::Spark.render(SparkModuleSpec::Hello)

      Azu::Spark.connection_count.should eq before
    end
  end

  describe ".configure" do
    it "yields the configuration shared with Azu::CONFIG" do
      Azu::Spark.configure { |config| config.should be(Azu::CONFIG.spark) }
    end
  end
end
