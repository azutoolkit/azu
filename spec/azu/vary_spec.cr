require "../spec_helper"

private def vary_of(existing : Array(String), add fields : Array(String)) : Array(String)
  headers = HTTP::Headers.new
  existing.each { |value| headers.add("Vary", value) }
  Azu::Vary.add(headers, fields)
  (headers.get?("Vary") || [] of String)
end

describe Azu::Vary do
  it "writes the one value when the response has no Vary" do
    vary_of([] of String, add: %w(Origin Accept)).should eq ["Origin,Accept"]
  end

  it "adds Accept to a Vary that holds Accept-Encoding (a prefix is not the field)" do
    vary_of(["Accept-Encoding"], add: %w(Accept)).should eq ["Accept-Encoding,Accept"]
  end

  it "adds Origin to a Vary that holds X-Origin (a suffix is not the field)" do
    vary_of(["X-Origin"], add: %w(Origin)).should eq ["X-Origin,Origin"]
  end

  it "compares whole tokens case-insensitively and does not repeat them" do
    vary_of(["accept-ENCODING, origin"], add: %w(Accept-Encoding ORIGIN)).should eq ["accept-ENCODING, origin"]
    vary_of(["origin"], add: %w(Origin Accept ACCEPT)).should eq ["origin,Accept"]
  end

  it "tolerates whitespace around tokens" do
    vary_of(["  Accept ,  Origin  "], add: %w(Accept Cookie)).should eq ["Accept ,  Origin,Cookie"]
  end

  it "leaves Vary: * alone, also with whitespace" do
    vary_of(["*"], add: %w(Accept)).should eq ["*"]
    vary_of(["  *  "], add: %w(Accept)).should eq ["  *  "]
    vary_of(["Accept-Encoding", " * "], add: %w(Accept)).should eq ["Accept-Encoding", " * "]
  end

  it "reads every Vary header line and writes one list" do
    vary_of(["Accept-Encoding", "Origin"], add: %w(Origin Accept)).should eq ["Accept-Encoding,Origin,Accept"]
    vary_of(["Accept-Encoding", "Accept"], add: %w(Accept)).should eq ["Accept-Encoding", "Accept"]
  end
end
