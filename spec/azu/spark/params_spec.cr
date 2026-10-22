require "../../spec_helper"

module SparkParamsSpec
  enum Mode
    Fast
    SlowMotion
  end

  struct ContactRequest
    include Azu::Request

    getter name : String
    getter age : Int32 = 0

    def initialize(@name : String = "", @age : Int32 = 0)
    end
  end
end

private def params(**values) : Azu::Spark::Params
  Azu::Spark::Params.new(JSON.parse(values.to_json).as_h)
end

describe Azu::Spark::Params do
  describe "#fetch" do
    it "converts strings and numbers to the requested scalar type" do
      data = params(count: "42", ratio: "0.5", flag: "on", name: 7, big: 3.0)

      data.fetch("count", Int32).should eq 42
      data.fetch("count", Int64).should eq 42_i64
      data.fetch("count", UInt8).should eq 42_u8
      data.fetch("ratio", Float64).should eq 0.5
      data.fetch("flag", Bool).should be_true
      data.fetch("name", String).should eq "7"
      data.fetch("big", Int32).should eq 3
    end

    it "understands the usual spellings of booleans" do
      %w(true on 1 yes).each { |value| params(v: value).fetch("v", Bool).should be_true }
      ["false", "off", "0", "no", ""].each { |value| params(v: value).fetch("v", Bool).should be_false }
      params(v: true).fetch("v", Bool).should be_true
      expect_raises(Azu::Spark::BadRequest) { params(v: "maybe").fetch("v", Bool) }
    end

    it "rejects values that do not fit and values out of range" do
      expect_raises(Azu::Spark::BadRequest, /'count' must be an integer/) { params(count: "many").fetch("count", Int32) }
      expect_raises(Azu::Spark::BadRequest, /within range/) { params(count: 300).fetch("count", UInt8) }
      expect_raises(Azu::Spark::BadRequest, /within range/) { params(count: -1).fetch("count", UInt32) }
      expect_raises(Azu::Spark::BadRequest) { params(count: 1.5).fetch("count", Int32) }
      expect_raises(Azu::Spark::BadRequest) { params(count: [1]).fetch("count", Int32) }
      expect_raises(Azu::Spark::BadRequest) { params(name: {a: 1}).fetch("name", String) }
    end

    it "treats a single value as a list and converts every element" do
      params(tags: ["a", "b"]).fetch("tags", Array(String)).should eq ["a", "b"]
      params(tags: "a").fetch("tags", Array(String)).should eq ["a"]
      params(ids: ["1", 2]).fetch("ids", Array(Int32)).should eq [1, 2]
    end

    it "parses enums by name" do
      params(mode: "fast").fetch("mode", SparkParamsSpec::Mode).should eq SparkParamsSpec::Mode::Fast
      params(mode: "slow_motion").fetch("mode", SparkParamsSpec::Mode).should eq SparkParamsSpec::Mode::SlowMotion
      expect_raises(Azu::Spark::BadRequest, /Fast, SlowMotion/) { params(mode: "warp").fetch("mode", SparkParamsSpec::Mode) }
    end

    it "honours defaults and nilable types for absent keys" do
      empty = params
      empty.fetch("page", Int32, 1).should eq 1
      empty.fetch("note", String?).should be_nil
      params(note: nil).fetch("note", String?).should be_nil
      params(note: "x").fetch("note", String?).should eq "x"
      expect_raises(Azu::Spark::BadRequest, /missing parameter 'page'/) { empty.fetch("page", Int32) }
    end

    it "builds an Azu::Request from the whole payload" do
      contact = params(name: "Ada", age: "36").fetch("anything", SparkParamsSpec::ContactRequest)

      contact.name.should eq "Ada"
      contact.age.should eq 36
      expect_raises(Azu::Spark::BadRequest, /ContactRequest/) { params(name: "Ada", age: "old").fetch("x", SparkParamsSpec::ContactRequest) }
    end
  end
end
