require "../../spec_helper"
require "../../support/spark_helpers"

private SECRET = "spec-secret-spec-secret-spec-secret"

private def claims(**values) : JSON::Any
  JSON.parse(values.to_json)
end

describe Azu::Spark::Token do
  it "round trips claims of the requested kind" do
    token = Azu::Spark::Token.sign("join", claims(user: "42"), 1.hour, SECRET)

    Azu::Spark::Token.verify("join", token, SECRET)["user"].as_s.should eq "42"
  end

  it "refuses tokens of another kind so a snapshot can never be used to join" do
    token = Azu::Spark::Token.sign("snapshot", claims(a: 1), 1.hour, SECRET)

    expect_raises(Azu::Spark::InvalidToken, /kind/) { Azu::Spark::Token.verify("join", token, SECRET) }
  end

  it "refuses tampered payloads and signatures" do
    token = Azu::Spark::Token.sign("join", claims(role: "user"), 1.hour, SECRET)
    payload, signature = token.split('.')
    forged = Base64.urlsafe_encode(%({"kind":"join","exp":9999999999,"claims":{"role":"admin"}}), padding: false)

    expect_raises(Azu::Spark::InvalidToken, /signature/) { Azu::Spark::Token.verify("join", "#{forged}.#{signature}", SECRET) }
    expect_raises(Azu::Spark::InvalidToken, /signature/) { Azu::Spark::Token.verify("join", "#{payload}.#{signature.reverse}", SECRET) }
    expect_raises(Azu::Spark::InvalidToken, /signature/) { Azu::Spark::Token.verify("join", "#{payload}.", SECRET) }
  end

  it "refuses tokens signed with another secret" do
    token = Azu::Spark::Token.sign("join", claims(a: 1), 1.hour, "another-secret")

    expect_raises(Azu::Spark::InvalidToken) { Azu::Spark::Token.verify("join", token, SECRET) }
  end

  it "refuses expired tokens" do
    token = Azu::Spark::Token.sign("join", claims(a: 1), -1.second, SECRET)

    expect_raises(Azu::Spark::InvalidToken, /expired/) { Azu::Spark::Token.verify("join", token, SECRET) }
  end

  it "refuses garbage and oversized input without parsing it" do
    ["", "abc", "a.b", "....", "💥.💥"].each do |garbage|
      expect_raises(Azu::Spark::InvalidToken) { Azu::Spark::Token.verify("join", garbage, SECRET) }
    end
    expect_raises(Azu::Spark::InvalidToken, /too large/) { Azu::Spark::Token.verify("join", "a" * 20_000, SECRET) }
  end

  describe Azu::Spark::Configuration do
    it "generates a stable random secret outside production" do
      config = Azu::Spark::Configuration.new
      config.secret = nil

      with_spark_env(Azu::Environment::Development) do
        config.secret.size.should eq 64
        config.secret.should eq config.secret
      end
    end

    it "refuses to run in production or staging without a configured secret" do
      config = Azu::Spark::Configuration.new
      config.secret = nil

      [Azu::Environment::Production, Azu::Environment::Staging].each do |env|
        with_spark_env(env) do
          expect_raises(Azu::Spark::ConfigurationError, /signing secret/) { config.secret }
        end
      end
    end

    it "uses the configured secret everywhere" do
      config = Azu::Spark::Configuration.new
      config.secret = "configured"

      with_spark_env(Azu::Environment::Production) { config.secret.should eq "configured" }
    end
  end
end
