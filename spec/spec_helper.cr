require "spec"
require "../src/azu"

ENV["CRYSTAL_ENV"] ||= "test"

# Simple dummy request type for specs
struct TestRequest
  include Azu::Request

  @name : String = ""
  @email : String = ""
  @age : Int32? = nil

  getter name, email, age

  def initialize(@name = "", @email = "", @age = nil)
  end
end
