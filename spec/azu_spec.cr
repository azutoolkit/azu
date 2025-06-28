require "./spec_helper.cr"
require "http/client"


process = Process.new("./bin/example_app")
# Wait for process to start
sleep 1.seconds

Spec.after_suite do
  process.not_nil!.signal Signal::KILL
end

describe Azu do
  client = HTTP::Client.new "localhost", 4000

  describe "coverting http request body to objects" do
    it "returns request as json" do
      payload = {id: 1, users: ["John", "Paul"], config: {"allowed" => true}}
      headers = HTTP::Headers{"Accept" => "application/json", "Content-Type" => "application/json"}

      response = client.post "/json/1", headers: headers, body: payload.to_json
      data = JSON.parse(response.body)

      response.status_code.should eq 200
      data["id"].should eq payload[:id]
      data["users"].should eq payload[:users]
      data["config"].should eq payload[:config]
    end
  end

  describe "Http Errors" do
    it "returns request not found" do
      response = client.get "/invalid_path", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 404
      response.body.should contain "Source: /invalid_path"
    end

    it "displays hello world" do
      response = client.get "/html/world", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 200
      response.body.should contain %q(Welcome, world)
    end
  end

  describe "Render HTML" do
    it "returns valid html" do
      name = "santa"
      response = client.get "/html/#{name}", headers: HTTP::Headers{"Accept" => "text/plain"}
      response.status_code.should eq 200
      response.body.should contain %(Welcome, #{name})
    end
  end

  describe "Http headers" do
    path = "/html?name=Elias"
    response = client.get path, headers: HTTP::Headers{"Accept" => "text/plain"}

    it "can set headers" do
      response.headers["Custom"].should contain %q(Fake custom header)
    end

    it "sets status code" do
      response.status_code.should eq 200
    end
  end
end
