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
    
    delegate :env, to: Azu

    def initialize(@context : HTTP::Server::Context, @ex : Azu::Error)
    end

    def html
      return ExceptionPage.for_runtime_exception(@context, @ex) if env.dev?
      # TODO Render generic error page
    end

    def json
      # TODO Append backtrace
      @ex.to_json
    end

    def text
      <<-TEXT
      Status: #{@ex.status}
      Link: #{@ex.link}
      Title: #{@ex.title}
      Detail: #{@ex.detail}
      Source: #{@ex.source}
      Backtrace: #{@ex.inspect_with_backtrace} 
      TEXT
    end
  end
end
