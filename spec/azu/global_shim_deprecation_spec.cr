require "../spec_helper"
require "log/spec"

private module ShimApp
  include Azu
end

describe "the global shim deprecation" do
  before_each { Azu.reset_shim_warning }

  it "logs one warning naming Azu::App the first time the shim is used" do
    Log.capture("Azu") do |logs|
      ShimApp.configure { }
      ShimApp.configure { }
      logs.check(:warn, /Azu::App.*migrate-to-0\.6/)
      logs.empty
    end
  end

  it "does not log when an app is built or its default is read" do
    Log.capture("Azu") do |logs|
      Azu::App.new.router
      Azu::App.default.router
      logs.empty
    end
  end

  it "warns again after the warning is reset" do
    Log.capture("Azu") do |logs|
      ShimApp.configure { }
      Azu.reset_shim_warning
      ShimApp.configure { }
      logs.check(:warn, /deprecated/)
      logs.check(:warn, /deprecated/)
      logs.empty
    end
  end
end
