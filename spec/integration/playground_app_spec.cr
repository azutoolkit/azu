require "../spec_helper"
require "../../src/azu/testing"

# Loads the getting-started app without starting its server and drives it in-process.
ENV["AZU_DEMO_NO_SERVER"] = "1"
require "../../playground/app"

describe "playground/app.cr" do
  client = Azu::Test::Client.new

  it "creates, lists and shows users" do
    created = client.post "/api/users", json: {email: "spec@example.com", name: "Spec"}
    created.status.should eq HTTP::Status::CREATED
    id = created.json["id"].as_i

    client.get("/api/users").json.as_a.map(&.["email"].as_s).should contain "spec@example.com"
    client.get("/api/users/#{id}").json["name"].as_s.should eq "Spec"
    client.get("/api/users/9999").status.should eq HTTP::Status::NOT_FOUND
  end

  it "validates params before the action runs" do
    bad = client.post "/api/users", json: {email: "nope", name: "S"}
    bad.status.should eq HTTP::Status::UNPROCESSABLE_ENTITY
    bad.json["FieldErrors"].as_h.keys.sort!.should eq %w(email name)

    client.get("/api/users", {limit: 500}, {"Accept" => "application/json"}).status.should eq HTTP::Status::UNPROCESSABLE_ENTITY
  end

  it "answers duplicates with a conflict" do
    client.post "/api/users", json: {email: "dup@example.com", name: "Dup"}
    again = client.post "/api/users", json: {email: "dup@example.com", name: "Dup"}
    again.status.should eq HTTP::Status::CONFLICT
  end

  it "returns a hash as JSON" do
    client.get("/health").json["status"].as_s.should eq "ok"
  end

  it "serves the page with live components" do
    page = client.get "/"
    page.status.should eq HTTP::Status::OK
    page.content_type.should eq "text/html"
    page.body.should contain "data-spark-view"
    page.body.should contain "spark-click='increment'"
  end

  it "validates the live form like the API" do
    signup = Demo::Signup.new
    signup.on_event("validate", {name: "A", email: "x"}.to_json)
    signup.errors.keys.sort!.should eq %w(email name)

    signup.on_event("save", {name: "Live User", email: "live@example.com"}.to_json)
    signup.welcome.should eq "Welcome, Live User!"
  end
end
