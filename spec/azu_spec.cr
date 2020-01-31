require "./spec_helper.cr"
require "http/client"

describe Azu do
  client = HTTP::Client.new Azu.config.host, Azu.config.port

  describe "Http Errors" do
    it "returns request not found" do
      invalid_path = "/invalid_path"
      response = client.get invalid_path

      response.status_code.should eq 404
      response.body.should contain "Path #{invalid_path} not defined"
    end

    it "returns params missing" do
      invalid_path = "/test/hello"
      response = client.get invalid_path

      response.status_code.should eq 400
      response.body.should contain "Param key {name} is not present!"
    end
  end

  describe "Http headers" do
    it "can set headers" do
      path = "/test/hello?name=Elias"
      response = client.get path

      response.headers["Custom"].should contain "Fake custom header"
    end
  end

  describe "Status Code" do
    it "sets status code" do 
      path = "/test/hello?name=Elias"
      response = client.get path

      response.status_code.should eq 300
      response.headers["Custom"].should contain "Fake custom header"
    end
  end
end
