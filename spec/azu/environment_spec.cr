require "../spec_helper"

describe Azu::Environment do
  describe "environment parsing" do
    it "parses build environment" do
      Azu::Environment.parse("build").should eq(Azu::Environment::Build)
    end

    it "parses development environment" do
      Azu::Environment.parse("development").should eq(Azu::Environment::Development)
    end

    it "parses test environment" do
      Azu::Environment.parse("test").should eq(Azu::Environment::Test)
    end

    it "parses integration environment" do
      Azu::Environment.parse("integration").should eq(Azu::Environment::Integration)
    end

    it "parses acceptance environment" do
      Azu::Environment.parse("acceptance").should eq(Azu::Environment::Acceptance)
    end

    it "parses pipeline environment" do
      Azu::Environment.parse("pipeline").should eq(Azu::Environment::Pipeline)
    end

    it "parses staging environment" do
      Azu::Environment.parse("staging").should eq(Azu::Environment::Staging)
    end

    it "parses production environment" do
      Azu::Environment.parse("production").should eq(Azu::Environment::Production)
    end

    it "raises error for invalid environment" do
      expect_raises(Exception) do
        Azu::Environment.parse("invalid")
      end
    end
  end

  describe "environment comparison" do
    it "checks if environment is in array of symbols" do
      env = Azu::Environment::Development

      env.in?([:development, :test]).should be_true
      env.in?([:production, :staging]).should be_false
    end

    it "checks if environment matches other environments" do
      env = Azu::Environment::Production

      env.in?(Azu::Environment::Production, Azu::Environment::Staging).should be_true
      env.in?(Azu::Environment::Development, Azu::Environment::Test).should be_false
    end

    it "handles single environment comparison" do
      env = Azu::Environment::Test

      env.in?(Azu::Environment::Test).should be_true
      env.in?(Azu::Environment::Production).should be_false
    end
  end

  describe "environment values" do
    it "has correct string representations" do
      Azu::Environment::Build.to_s.should eq("Build")
      Azu::Environment::Development.to_s.should eq("Development")
      Azu::Environment::Test.to_s.should eq("Test")
      Azu::Environment::Integration.to_s.should eq("Integration")
      Azu::Environment::Acceptance.to_s.should eq("Acceptance")
      Azu::Environment::Pipeline.to_s.should eq("Pipeline")
      Azu::Environment::Staging.to_s.should eq("Staging")
      Azu::Environment::Production.to_s.should eq("Production")
    end
  end

  describe "environment ordering" do
    it "maintains correct order" do
      # Verify that environments are ordered as expected
      environments = [
        Azu::Environment::Build,
        Azu::Environment::Development,
        Azu::Environment::Test,
        Azu::Environment::Integration,
        Azu::Environment::Acceptance,
        Azu::Environment::Pipeline,
        Azu::Environment::Staging,
        Azu::Environment::Production,
      ]

      environments.size.should eq(8)
      environments.first.should eq(Azu::Environment::Build)
      environments.last.should eq(Azu::Environment::Production)
    end
  end
end
