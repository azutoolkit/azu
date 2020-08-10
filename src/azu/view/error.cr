require "ecr"
require "exception_page"

module Azu
  class ErrorView
    include Html
    include Json
    include Text

    class ExceptionPage < ::ExceptionPage
      def styles : ExceptionPage::Styles
        ::ExceptionPage::Styles.new(
          accent: "red",
        )
      end
    end

    def initialize(@context : HTTP::Server::Context, @ex : Azu::Error)
    end

    def render
      ECR.render "#{__DIR__}/error.ecr"
    end

    def html
      return ExceptionPage.for_runtime_exception(@context, @ex) if ENVIRONMENT.development?
      to_s
    end

    def json
      {
        Status:    @ex.status,
        Link:      @ex.link,
        Title:     @ex.title,
        Detail:    @ex.detail,
        Source:    @ex.source,
        Errors:    @ex.errors,
        Backtrace: @ex.inspect_with_backtrace,
      }.to_json
    end

    def text
      <<-TEXT
      Status: #{@ex.status}
      Link: #{@ex.link}
      Title: #{@ex.title}
      Detail: #{@ex.detail}
      Source: #{@ex.source}
      Errors: #{@ex.errors}
      Backtrace: #{@ex.inspect_with_backtrace}
      TEXT
    end
  end
end