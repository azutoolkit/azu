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
