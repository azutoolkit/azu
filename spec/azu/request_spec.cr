require "../spec_helper"

module Azu::RequestSpec
  struct TestRequest
    include Azu::Request

    @name : String
    @age : Int32?
    @active : Bool

    getter name, age, active

    def initialize(@name : String = "", @age : Int32? = nil, @active : Bool = false)
    end
  end

  struct TestSerializableRequest
    include Azu::Request

    @name : String
    @age : Int32?

    getter name, age

    def initialize(@name : String = "", @age : Int32? = nil)
    end
  end

  struct TestQueryRequest
    include Azu::Request

    @name : String

    getter name

    def initialize(@name : String = "")
    end
  end

  struct TestValidationRequest
    include Azu::Request

    @email : String

    getter email

    def initialize(@email : String = "")
    end

    validate email, presence: true, message: "Email is required"
  end
end

describe Azu::Request do
  describe "URI::Params::Serializable integration" do
    it "creates request from URL-encoded form data" do
      form_data = "name=John&age=25&active=true"
      request = Azu::RequestSpec::TestRequest.from_www_form(form_data)

      request.name.should eq "John"
      request.age.should eq 25
      request.active.should eq true
    end

    it "serializes request to URL-encoded form data" do
      request = Azu::RequestSpec::TestSerializableRequest.new(name: "Jane", age: 30)
      form_data = request.to_www_form

      form_data.should contain "name=Jane"
      form_data.should contain "age=30"
    end

    it "maintains compatibility with from_query method" do
      query_string = "name=Test"
      request = Azu::RequestSpec::TestQueryRequest.from_query(query_string)

      request.name.should eq "Test"
    end

    it "works with validation" do
      form_data = "email=test@example.com"
      request = Azu::RequestSpec::TestValidationRequest.from_www_form(form_data)

      request.email.should eq "test@example.com"
      request.valid?.should be_true
    end

    it "handles validation errors" do
      request = Azu::RequestSpec::TestValidationRequest.new
      request.valid?.should be_false
      request.error_messages.should contain "Email is required"
    end
  end
end
