require "spec"
require "../src/azu"

ENV["CRYSTAL_ENV"] ||= "test"

# Runs the block with Azu::CONFIG.env switched, restoring it afterwards.
def with_azu_env(env : Azu::Environment, &)
  original = Azu::CONFIG.env
  Azu::CONFIG.env = env
  begin
    yield
  ensure
    Azu::CONFIG.env = original
  end
end

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
