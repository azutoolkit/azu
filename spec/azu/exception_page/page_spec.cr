require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

private EVIL = %(<script>alert(1)</script>)
# Built, not written out: the page shows the source around the failing line, which is in this file.
private SECRET = "hun" + "ter2"

# Runs `failure` behind RequestId and Rescuer in `env`, the way an app's stack does, and returns the response.
private def serve_failure(env : Azu::Environment, accept : String, path : String = "/orders/7", headers = HTTP::Headers.new, &failure : HTTP::Server::Context ->)
  rescuer = Azu::Handler::Rescuer.new
  rescuer.next = ->(context : HTTP::Server::Context) { failure.call(context); nil }
  request_id = Azu::Handler::RequestId.new
  request_id.next = rescuer
  headers["Accept"] = accept
  context, io = create_context("GET", path, headers)
  with_azu_env(env) { request_id.call(context) }
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io)
end

private def json_body(response : HTTP::Client::Response) : JSON::Any
  JSON.parse(response.body)
end

describe Azu::ExceptionPage do
  describe "in development" do
    it "triages the exception: class, message, where the app raised it and the likely cause" do
      response = serve_failure(Azu::Environment::Development, "text/html") { |_context| {"a" => 1}["id"] }
      html = response.body

      response.status_code.should eq 500
      html.should contain "KeyError"
      html.should contain %(Missing hash key: &quot;id&quot;)
      html.should contain "page_spec.cr:"
      html.should contain "Likely cause"
      html.should contain %(The key &quot;id&quot; is missing)
    end

    it "shows the request id the request ran under" do
      response = serve_failure(Azu::Environment::Development, "text/html") { |_context| raise "boom" }
      request_id = response.headers["X-Request-ID"]

      response.body.should contain request_id
    end

    it "escapes what the request and the exception carry" do
      headers = HTTP::Headers{"X-Evil" => EVIL, "User-Agent" => EVIL}
      response = serve_failure(Azu::Environment::Development, "text/html", "/x?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E", headers) { |_context| raise EVIL }
      html = response.body

      html.should_not contain EVIL
      html.should contain "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    it "keeps credentials out of the page" do
      headers = HTTP::Headers{"Authorization" => "Bearer #{SECRET}", "Cookie" => "session=#{SECRET}-cookie"}
      response = serve_failure(Azu::Environment::Development, "text/html", "/x?token=#{SECRET}&page=2", headers) do |context|
        context.response.headers["X-Api-Key"] = "#{SECRET}-header"
        raise "boom"
      end

      response.body.should_not contain SECRET
      response.body.should contain "[FILTERED]"
    end

    it "is one self-contained document, in light and dark" do
      html = serve_failure(Azu::Environment::Development, "text/html") { |_context| raise "boom" }.body

      html.should start_with "<!DOCTYPE html>"
      html.should_not match(/(?:src|href)=['"]https?:/)
      html.should_not contain "rel='stylesheet'"
      html.should contain "light-dark("
      html.should contain %(data-action='theme')
    end

    it "links to the dev dashboard only when one is mounted" do
      Azu::ExceptionPage.isolate do
        Azu::ExceptionPage.dashboard_path = nil
        report = Azu::ExceptionPage::Report.build(Exception.new("boom"))
        report.recorded = true
        Azu::ExceptionPage.new(report).render.should_not contain "/dev-dashboard"

        Azu::ExceptionPage.dashboard_path = "/dev-dashboard"
        Azu::ExceptionPage.new(report).render.should contain "/dev-dashboard/errors/#{report.id}"
      end
    end

    it "adds the triage to the JSON problem body, next to the members it always had" do
      json = json_body(serve_failure(Azu::Environment::Development, "application/json") { |_context| {"a" => 1}["id"] })

      json["title"].should eq %(Missing hash key: "id")
      json["backtrace"].as_s.should contain "page_spec.cr"
      exception = json["exception"]
      exception["class"].should eq "KeyError"
      exception["location"]["file"].as_s.should end_with "page_spec.cr"
      exception["hints"][0]["title"].should eq %(The key "id" is missing)
      exception["request"]["id"].as_s.should start_with "req_"
    end

    it "puts the triage at the top of the text body" do
      body = serve_failure(Azu::Environment::Development, "text/plain") { |_context| {"a" => 1}["id"] }.body

      body.should start_with %(KeyError: Missing hash key: "id")
      body.should contain "Raised in: "
      body.should contain %(Likely cause: The key "id" is missing)
    end

    it "lists the queries of the failing request, with the one that failed" do
      store = Azu::QueryStore.instance
      store.enabled = true
      begin
        response = serve_failure(Azu::Environment::Development, "application/json") do |_context|
          id = Azu::RequestContext.current?.not_nil!.request_id
          3.times { |n| store.record_query("SELECT * FROM users WHERE id = $1", [n.to_s], 1.0, 1_i64, nil, nil, nil, id, "Show", "GET", "/orders/7", 1_u64) }
          store.record_query("INSERT INTO orders VALUES ($1)", ["1"], 2.0, nil, "duplicate key", "src/orders.cr:9", nil, id, "Show", "GET", "/orders/7", 1_u64)
          store.record_query("SELECT 1", [] of String, 1.0, 1_i64, nil, nil, nil, "req_other", "Other", "GET", "/", 1_u64)
          raise "boom"
        end
        exception = json_body(response)["exception"]
        database = exception["signals"].as_a.find! { |panel| panel["title"] == "Database" }

        database["stats"][0]["value"].should eq "4"
        database["rows"].as_a.size.should eq 4
        titles = exception["hints"].as_a.map(&.["title"].as_s)
        titles.should contain "A SQL statement failed: duplicate key"
        titles.should contain "N+1: the same query ran 3 times in this request"
      ensure
        store.enabled = false
        store.clear
      end
    end
  end

  describe "outside development" do
    it "answers with the generic page: no class, message, file, fingerprint or request data" do
      response = serve_failure(Azu::Environment::Production, "text/html", "/x?token=#{SECRET}") { |_context| raise "password authentication failed" }
      html = response.body

      html.should contain "<h1>500</h1>"
      html.should contain "Something went wrong on our end"
      html.should contain response.headers["X-Error-ID"]
      {"password authentication", "RuntimeError", "Exception", "page_spec", "src/", SECRET, response.headers["X-Error-Fingerprint"], "/x"}.each do |leak|
        html.should_not contain leak
      end
      html.should_not match(/(?:src|href)=['"]https?:/)
    end

    it "keeps the JSON body to its problem members" do
      json = json_body(serve_failure(Azu::Environment::Production, "application/json") { |_context| raise "boom" })

      json.as_h.keys.sort.should eq ["detail", "error_id", "errors", "instance", "status", "title", "type"]
    end

    it "keeps the triage out even when an exception subscriber builds the report" do
      Azu::Instrumentation.isolate do
        seen = [] of String
        Azu::Instrumentation.on_exception { |report| seen << report.exception_class }
        response = serve_failure(Azu::Environment::Production, "application/json") { |_context| raise "boom" }

        seen.should eq ["Exception"]
        json_body(response).as_h.has_key?("exception").should be_false
      end
    end

    it "says what a status means in plain words" do
      {404 => "We couldn&#39;t find that page", 429 => "Slow down a little", 503 => "We&#39;ll be right back"}.each do |status, words|
        error = Azu::Response::Error.new("Status #{status}", HTTP::Status.new(status), [] of String)
        with_azu_env(Azu::Environment::Production) { error.html }.should contain words
      end
    end
  end
end
