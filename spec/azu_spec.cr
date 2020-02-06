require "./spec_helper.cr"
require "http/client"

describe Azu do
  client = HTTP::Client.new "localhost", Azu.config.port

  describe "Http Errors" do
    it "returns request not found" do
      response = client.get "/invalid_path", headers: HTTP::Headers{"Accept" => "text/plain"}

      response.status_code.should eq 404
      response.body.should contain %q(Path /invalid_path not defined)
    end

    it "returns params missing" do
      response = client.get "/test/hello", headers: HTTP::Headers{"Accept" => "text/plain"}

      response.status_code.should eq 500
      response.body.should contain %q(Missing param name: ".name")
    end
  end

  describe "Http headers" do
    path = "/test/hello?name=Elias"
    response = client.get path, headers: HTTP::Headers{"Accept" => "text/plain"}

    it "can set headers" do
      response.headers["Custom"].should contain %q(Fake custom header)
    end

    it "sets status code" do
      response.status_code.should eq 300
    end
  end
end
