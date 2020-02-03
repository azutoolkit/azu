require "ecr"
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

    ECR.def_to_s "./src/azu/views/error.ecr"

    def initialize(@context : HTTP::Server::Context, @ex : Azu::Error)
    end

    def html
      return ExceptionPage.for_runtime_exception(@context, @ex) if env.development?
      to_s
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
      Errors: #{@ex.errors} 
      Backtrace: #{@ex.inspect_with_backtrace} 
      TEXT
    end
  end
end
