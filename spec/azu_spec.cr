require "./spec_helper.cr"
require "http/client"

describe Azu do
  client = HTTP::Client.new "localhost", 4000

  describe "Http Errors" do
    it "returns request not found" do
      response = client.get "/invalid_path", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 404
      response.body.should contain %q(Path /invalid_path not defined)
    end

    it "returns params missing" do
      response = client.get "/test/hello", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 200
      response.body.should contain %q(Welcome, World!)
    end
  end

  describe "Render HTML" do
    it "returns valid html" do
      name = "santa"
      response = client.get "/test/hello/#{name}", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 200
      response.body.should contain %(Welcome, #{name})
    end
  end

  describe "Renders JSON" do
    it "reders valid json" do
      response = client.get "/test/hello/json", headers: HTTP::Headers{"Accept" => "application/json"}
      response.status_code.should eq 200
      response.body.should eq %({"data":"Hello World"})
    end
  end

  describe "Http headers" do
    path = "/test/hello?name=Elias"
    response = client.get path, headers: HTTP::Headers{"Accept" => "text/plain"}

    it "can set headers" do
      response.headers["Custom"].should contain %q(Fake custom header)
    end

    it "sets status code" do
      response.status_code.should eq 200
    end
  end
end
