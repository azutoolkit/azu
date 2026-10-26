require "../../spec_helper"

describe Azu::Handler::TrustedHeader do
  it "replaces the value under any spelling of the name, as HTTP::Headers#[]= does" do
    headers = HTTP::Headers{"x_request_id" => "old"}
    Azu::Handler::TrustedHeader.set(headers, Azu::Handler::TrustedHeader.key("X-Request-ID"), "new")

    headers.to_a.should eq [{"x_request_id", ["new"]}]
  end

  # What the helper is for, and the contract for its callers: the value must be valid already. If a Crystal release
  # starts checking here, the shortcut is gone and `HTTP::Headers#[]=` costs the same.
  it "does not check the value again" do
    headers = HTTP::Headers.new
    Azu::Handler::TrustedHeader.set(headers, Azu::Handler::TrustedHeader.key("X-Test"), "unchecked\n")

    headers["X-Test"].should eq "unchecked\n"
  end
end
