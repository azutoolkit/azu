require "../../spec_helper"

describe Azu::Handler::Locale do
  available = ["en", "es", "pt-BR"]

  describe ".negotiate" do
    {
      nil                                                              => "en",
      ""                                                               => "en",
      "es"                                                             => "es",
      "es-ES,es;q=0.9,en;q=0.8"                                        => "es",
      "en;q=0.5,es;q=0.9"                                              => "es",
      "es,en"                                                          => "es",
      "fr;q=0.9,es;q=0.8,en;q=0.5"                                     => "es",
      "fr,de"                                                          => "en",
      "fr,es;q=0.1"                                                    => "es",
      "es;q=0"                                                         => "en",
      "*"                                                              => "en",
      "pt"                                                             => "pt-BR",
      "PT-br"                                                          => "pt-BR",
      "en-GB"                                                          => "en",
      ";q=1,es"                                                        => "es",
      "es;q=abc,en"                                                    => "en",
      (%w(a b c d e f g h i j k l m n o p q r s t) + %w(es)).join(",") => "en",
    }.each do |header, expected|
      it "picks #{expected} for #{header.inspect}" do
        Azu::Handler::Locale.negotiate(header, available, "en").should eq expected
      end
    end
  end

  describe "#call" do
    original_available = Azu::Helpers::I18n.config.available_locales
    original_default = Azu::Helpers::I18n.config.default_locale

    around_each do |example|
      Azu::Helpers::I18n.config.available_locales = ["en", "es"]
      Azu::Helpers::I18n.config.default_locale = "en"
      begin
        example.run
      ensure
        Azu::Helpers::I18n.config.available_locales = original_available
        Azu::Helpers::I18n.config.default_locale = original_default
      end
    end

    # Runs the request through the handler and returns the locale the next handler saw
    serve = ->(headers : HTTP::Headers, handler : Azu::Handler::Locale, seen : Array(String)) do
      handler.next = ->(context : HTTP::Server::Context) do
        seen << Azu::Helpers::I18n.locale
        nil
      end
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/", headers), HTTP::Server::Response.new(IO::Memory.new))
      handler.call(context)
    end

    it "serves the request in the locale its Accept-Language asks for and restores it afterwards" do
      seen = [] of String

      serve.call(HTTP::Headers{"Accept-Language" => "es-MX,es;q=0.9,en;q=0.8"}, Azu::Handler::Locale.new, seen)

      seen.should eq ["es"]
      Azu::Helpers::I18n.locale.should eq "en"
    end

    it "serves a request without the header in the default locale" do
      seen = [] of String

      serve.call(HTTP::Headers.new, Azu::Handler::Locale.new, seen)

      seen.should eq ["en"]
    end

    it "does not carry a locale assigned during one request into the next on the same fiber" do
      handler = Azu::Handler::Locale.new
      handler.next = ->(context : HTTP::Server::Context) do
        Azu::Helpers::I18n.locale = "es"
        nil
      end
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))
      handler.call(context)

      Azu::Helpers::I18n.locale.should eq "en"

      seen = [] of String
      serve.call(HTTP::Headers.new, Azu::Handler::Locale.new, seen)
      seen.should eq ["en"]
    end

    it "gives concurrent requests their own locales" do
      results = Channel({String, String}).new
      %w(es en es en).each do |language|
        spawn do
          seen = [] of String
          handler = Azu::Handler::Locale.new
          handler.next = ->(context : HTTP::Server::Context) do
            Fiber.yield
            seen << Azu::Helpers::I18n.locale
            nil
          end
          context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/", HTTP::Headers{"Accept-Language" => language}), HTTP::Server::Response.new(IO::Memory.new))
          handler.call(context)
          results.send({language, seen.first})
        end
      end

      4.times.map { results.receive }.each do |language, seen|
        seen.should eq language
      end
    end
  end
end
