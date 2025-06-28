require "../spec_helper"

describe Azu::ContentNegotiator do
  describe "content type negotiation" do
    it "sets HTML content type for HTML accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("text/html")
    end

    it "sets JSON content type for JSON accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "application/json,text/javascript,*/*;q=0.01"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("application/json")
    end

    it "sets XML content type for XML accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "application/xml,text/xml,*/*;q=0.01"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("application/xml")
    end

    it "sets plain text content type for plain accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/plain,*/*;q=0.01"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("text/plain")
    end

    it "sets wildcard content type for wildcard accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "*/*"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("*/*")
    end

    it "respects quality values in accept header" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "text/html;q=0.8,application/json;q=0.9,text/plain;q=1.0"
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      # Should choose the highest quality value first
      response.headers["content_type"].should eq("text/plain")
    end

    it "does not override existing content type" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = "application/json"
      response = HTTP::Server::Response.new(IO::Memory.new)
      response.headers["content_type"] = "text/html"
      context = HTTP::Server::Context.new(request, response)

      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"].should eq("text/html")
    end

    it "handles missing accept header gracefully" do
      request = HTTP::Request.new("GET", "/")
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      # Should not raise an exception
      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"]?.should be_nil
    end

    it "handles empty accept header gracefully" do
      request = HTTP::Request.new("GET", "/")
      request.headers["Accept"] = ""
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      # Should not raise an exception
      Azu::ContentNegotiator.content_type(context)

      response.headers["content_type"]?.should be_nil
    end
  end
end
