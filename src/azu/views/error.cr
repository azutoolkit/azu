require "exception_page"

module Azu
  class Views::Error < View
    class ExceptionPage < ::ExceptionPage
      def styles : ExceptionPage::Styles
        ::ExceptionPage::Styles.new(
          accent: "red",
        )
      end
    end

    def initialize(@context : HTTP::Server::Context, @ex : Azu::Error)
    end

    def html
      ExceptionPage.for_runtime_exception(@context, @ex)
    end

    def json
      @ex.to_json
    end

    def text
      <<-TEXT
      Status: #{@ex.status}
      Link: #{@ex.link}
      Title: #{@ex.title}
      Detail: #{@ex.detail}
      Source: #{@ex.source}
      TEXT
    end
  end
end
