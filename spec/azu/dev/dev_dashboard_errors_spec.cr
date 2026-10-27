require "../../spec_helper"
require "../../../src/azu/dev/dev"
require "../../support/integration_helpers"

include IntegrationHelpers

private def fail_request(path : String, message : String, error : Exception.class = Exception) : Nil
  rescuer = Azu::Handler::Rescuer.new
  rescuer.next = ->(_context : HTTP::Server::Context) { raise error.new(message) }
  context, _io = create_context("GET", path, HTTP::Headers{"Accept" => "application/json"})
  rescuer.call(context)
end

private def get(handler : HTTP::Handler, path : String, accept : String = "text/html") : HTTP::Client::Response
  context, io = create_context("GET", path, HTTP::Headers{"Accept" => accept})
  handler.call(context)
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io)
end

describe Azu::ErrorStore do
  around_each do |example|
    Azu::ErrorStore.instance.clear
    with_azu_env(Azu::Environment::Development) { example.run }
    Azu::ErrorStore.instance.clear
  end

  it "keeps every server error the Rescuer answers, grouped by where it was raised" do
    3.times { |n| fail_request("/orders/#{n}", "order #{n} failed") }
    fail_request("/users", "other", ArgumentError)

    groups = Azu::ErrorStore.instance.groups
    groups.map(&.count).sort.should eq [1, 3]
    groups.find!(&.count.==(3)).message.should eq "order 2 failed"
  end

  it "places a report among its occurrences" do
    3.times { fail_request("/orders", "boom") }
    group = Azu::ErrorStore.instance.groups.first
    middle = Azu::ErrorStore.instance.report(group.report_ids[1]).not_nil!

    occurrence = Azu::ErrorStore.instance.occurrence(middle).not_nil!
    occurrence.index.should eq 2
    occurrence.total.should eq 3
    occurrence.previous_id.should eq group.report_ids[0]
    occurrence.next_id.should eq group.report_ids[2]
  end

  it "stays bounded" do
    store = Azu::ErrorStore.new
    (Azu::ErrorStore::MAX_REPORTS + 5).times { store.record(Azu::ExceptionPage::Report.build(Exception.new("x"))) }

    store.groups.first.count.should eq Azu::ErrorStore::MAX_REPORTS + 5
    store.groups.first.report_ids.size.should eq Azu::ErrorStore::MAX_REPORTS
  end

  it "keeps nothing outside development" do
    with_azu_env(Azu::Environment::Production) { fail_request("/orders", "boom") }

    Azu::ErrorStore.instance.size.should eq 0
  end

  it "feeds the exception page's performance context" do
    fail_request("/orders", "boom")
    report = Azu::ErrorStore.instance.report(Azu::ErrorStore.instance.groups.first.latest_id.not_nil!).not_nil!

    report.panels.map(&.title).should contain "Performance context"
    report.panels.find!(&.title.==("Performance context")).stats.map(&.label).should contain "GC heap"
  end
end

describe "Azu::Handler::DevDashboard errors" do
  around_each do |example|
    Azu::ErrorStore.instance.clear
    with_azu_env(Azu::Environment::Development) { example.run }
    Azu::ErrorStore.instance.clear
  end

  it "lists the errors in an Errors tab that links to their exception pages" do
    dashboard = Azu::Handler::DevDashboard.new
    fail_request("/orders", "order failed")
    id = Azu::ErrorStore.instance.groups.first.latest_id

    html = get(dashboard, "/dev-dashboard").body
    html.should contain %(id='tab-errors')
    html.should contain "order failed"
    html.should contain "/dev-dashboard/errors/#{id}"
  end

  it "says when there is no error yet" do
    get(Azu::Handler::DevDashboard.new, "/dev-dashboard").body.should contain "No server errors since boot"
  end

  it "renders a kept error as its exception page, with the occurrences around it" do
    dashboard = Azu::Handler::DevDashboard.new
    2.times { fail_request("/orders", "order failed") }
    group = Azu::ErrorStore.instance.groups.first

    response = get(dashboard, "/dev-dashboard/errors/#{group.report_ids.first}")
    response.status_code.should eq 200
    response.body.should contain "order failed"
    response.body.should contain "Occurrence 1 of 2"
    response.body.should contain "/dev-dashboard/errors/#{group.report_ids.last}"
    response.body.should contain %(href='/dev-dashboard#errors')
  end

  it "answers JSON for tools" do
    dashboard = Azu::Handler::DevDashboard.new
    fail_request("/orders", "order failed")
    id = Azu::ErrorStore.instance.groups.first.latest_id

    list = JSON.parse(get(dashboard, "/dev-dashboard/errors.json", "application/json").body)
    list[0]["message"].should eq "order failed"
    list[0]["url"].should eq "/dev-dashboard/errors/#{id}"

    JSON.parse(get(dashboard, "/dev-dashboard/errors/#{id}.json").body)["class"].should eq "Exception"
    JSON.parse(get(dashboard, "/dev-dashboard/errors/#{id}", "application/json").body)["id"].should eq id
  end

  it "answers 404 for an error it no longer keeps" do
    response = get(Azu::Handler::DevDashboard.new, "/dev-dashboard/errors/nope")

    response.status_code.should eq 404
    response.body.should contain "no longer kept"
  end

  it "links the error page to the kept report" do
    Azu::Handler::DevDashboard.new
    rescuer = Azu::Handler::Rescuer.new
    rescuer.next = ->(_context : HTTP::Server::Context) { raise "boom" }
    context, io = create_context("GET", "/orders", HTTP::Headers{"Accept" => "text/html"})
    rescuer.call(context)
    context.response.close
    io.rewind

    id = Azu::ErrorStore.instance.groups.first.latest_id
    HTTP::Client::Response.from_io(io).body.should contain "/dev-dashboard/errors/#{id}"
  end

  it "serves none of it outside development" do
    dashboard = Azu::Handler::DevDashboard.new
    dashboard.next = ->(context : HTTP::Server::Context) { context.response.status_code = 404; nil }

    with_azu_env(Azu::Environment::Production) do
      get(dashboard, "/dev-dashboard/errors.json", "application/json").status_code.should eq 404
      get(dashboard, "/dev-dashboard/errors/anything").status_code.should eq 404
    end
  end
end
