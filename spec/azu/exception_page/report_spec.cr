require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

private class SpecPaymentError < Exception
end

private def raised(exception : Exception) : Exception
  raise exception
rescue ex
  ex
end

private def report_for(exception : Exception, path = "/orders/7?token=hunter2&page=2", headers = HTTP::Headers.new) : Azu::ExceptionPage::Report
  context, _io = create_context("GET", path, headers)
  Azu::ExceptionPage::Report.build(raised(exception), context)
end

describe Azu::ExceptionPage::Report do
  it "reports the exception a Response::Error was made from" do
    context, _io = create_context("GET", "/boom")
    error = Azu::Response::Error.from_exception(raised(KeyError.new(%(Missing hash key: "id"))), 500)
    report = with_azu_env(Azu::Environment::Development) { error.exception_report(context) }

    report.exception_class.should eq "KeyError"
    report.status.should eq 500
    report.error_id.should eq error.error_id
    report.location.not_nil!.file.should end_with "report_spec.cr"
  end

  it "redacts the request it keeps" do
    headers = HTTP::Headers{"Authorization" => "Bearer hunter2", "Cookie" => "session=hunter2; theme=dark"}
    report = report_for(Exception.new("boom"), headers: headers)
    kept = report.request.to_s + report.request.params.to_s + report.request.headers.to_s + report.request.cookies.to_s

    kept.should_not contain "hunter2"
    report.request.params.should contain({"page", "2"})
    report.request.cookies.should contain({"theme", "dark"})
  end

  it "groups occurrences by class and where the app raised it, not by message" do
    first = report_for(KeyError.new("Missing hash key: \"a\""))
    again = report_for(KeyError.new("Missing hash key: \"b\""))
    other = report_for(IndexError.new)

    first.fingerprint.should eq again.fingerprint
    first.fingerprint.should_not eq other.fingerprint
  end

  it "keeps the causes, with where each was raised" do
    error = begin
      begin
        raise IO::Error.new("disk full")
      rescue ex
        raise Exception.new("could not save", cause: ex)
      end
    rescue outer
      outer
    end
    report = Azu::ExceptionPage::Report.build(error)

    report.causes.map(&.exception_class).should eq ["IO::Error"]
    report.causes.first.location.not_nil!.file.should end_with "report_spec.cr"
  end

  it "writes Markdown to paste into an issue" do
    markdown = report_for(KeyError.new(%(Missing hash key: "id"))).to_markdown

    markdown.should start_with %(## KeyError: Missing hash key: "id")
    markdown.should contain "- Request: `GET /orders/7?token=[FILTERED]&page=2`"
    markdown.should contain "### Likely causes"
    markdown.should contain "report_spec.cr"
  end

  it "has a JSON form for API clients" do
    json = JSON.parse(report_for(KeyError.new(%(Missing hash key: "id"))).to_json)

    json["class"].should eq "KeyError"
    json["location"]["file"].as_s.should end_with "report_spec.cr"
    json["location"]["kind"].should eq "app"
    json["hints"][0]["title"].should eq %(The key "id" is missing)
    json["frames"].as_a.should_not be_empty
    json["request"]["method"].should eq "GET"
    json["dashboard_url"].raw.should be_nil
  end
end

describe "Azu::ExceptionPage triage" do
  it "explains well-known exceptions and names where they were raised" do
    titles = ->(exception : Exception) { report_for(exception).hints.map(&.title) }

    titles.call(NilAssertionError.new).should contain "A value was nil where the code assumed it was not"
    titles.call(KeyError.new(%(Missing hash key: "email"))).should contain %(The key "email" is missing)
    titles.call(IndexError.new).should contain "An index is out of bounds"
    titles.call(DivisionByZeroError.new).should contain "Division by zero"
    titles.call(Socket::ConnectError.new("refused")).should contain "A service refused the connection"
    titles.call(Crinja::TemplateNotFoundError.new("missing.jinja")).should contain "The template file was not found"
    report_for(NilAssertionError.new).hints.first.detail.should contain "report_spec.cr"
  end

  it "names connection settings without printing them" do
    ENV["DATABASE_URL"] = "postgres://app:hunter2@db/app"
    hint = report_for(Socket::ConnectError.new("refused")).hints.first
    hint.detail.should contain "DATABASE_URL is set"
    hint.detail.should_not contain "hunter2"
  ensure
    ENV.delete("DATABASE_URL")
  end

  it "takes likely causes an app registers, most severe first" do
    Azu::ExceptionPage.isolate do
      Azu::ExceptionPage.hint(SpecPaymentError) { |_error, _report| Azu::ExceptionPage::Hint.new("Card declined", "ask for another card", :info) }
      Azu::ExceptionPage.hint(SpecPaymentError) { |_error, _report| Azu::ExceptionPage::Hint.new("Gateway down", "retry later", :bad) }
      Azu::ExceptionPage.hint(IndexError) { |_error, _report| Azu::ExceptionPage::Hint.new("never", "not this class", :bad) }

      report_for(SpecPaymentError.new).hints.map(&.title).should eq ["Gateway down", "Card declined"]
    end
  end

  it "adds the panels providers return, and survives one that raises" do
    Azu::ExceptionPage.isolate do
      Azu::ExceptionPage.on_panels { |_report| raise "provider bug" }
      Azu::ExceptionPage.on_panels do |report|
        [Azu::ExceptionPage::Panel.new("Jobs", stats: [Azu::ExceptionPage::Stat.new("Failed", "3", :warn)],
          hints: [Azu::ExceptionPage::Hint.new("Jobs are failing too", report.request.path, :warn)])]
      end

      report = report_for(SpecPaymentError.new)
      report.panels.map(&.title).should eq ["Jobs"]
      report.hints.map(&.title).should eq ["Jobs are failing too"]
    end
  end
end
