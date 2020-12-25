require "ecr"
require "exception_page"

module Azu
  class ExceptionPage < ::ExceptionPage
    def styles : ExceptionPage::Styles
      ::ExceptionPage::Styles.new(
        accent: "red",
      )
    end
  end

  module Response
    class Error < Exception
      include Azu::Response

      property status : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR
      property title : String = "Internal Server Error"
      property detail : String = "Internal Server Error"
      property source : String = ""
      property errors : Array(String) = [] of String
      
      private getter templates : Templates = CONFIG.templates
      private getter env : Environment = CONFIG.env
      private getter log : ::Log = CONFIG.log

      def initialize(@detail = "", @source = "", @errors = Array(String).new)
      end

      def initialize(@title, @status, @errors)
      end

      def self.from_exception(ex)
        new detail: ex.message || "An Error has occurred"
      end

      def link
        "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status}"
      end

      def html(context)
        return ExceptionPage.for_runtime_exception(context, self).to_s if env.development?
        html
      end

      def html
        render "error.html", {
          status:    status.value,
          link:      link,
          title:     title,
          detail:    detail,
          source:    source,
          errors:    errors,
          backtrace: inspect_with_backtrace,
        }
      end

      def render(template : String, data)
        templates.load(template).render(data)
      end

      def xml
        # Todo Implement XML
      end

      def json
        {
          Status:    status,
          Link:      link,
          Title:     title,
          Detail:    detail,
          Source:    source,
          Errors:    errors,
          Backtrace: inspect_with_backtrace,
        }.to_json
      end

      def text
        <<-TEXT
      Status: #{status}
      Link: #{link}
      Title: #{title}
      Detail: #{detail}
      Source: #{source}
      Errors: #{errors}
      Backtrace: #{inspect_with_backtrace}
      TEXT
      end
    end

    class BadRequest < Error
      getter title = "Bad Request"
      getter status : HTTP::Status = HTTP::Status::BAD_REQUEST
    end

    class NotFound < Error
      def initialize(path : String)
        @title = "Not found"
        @detail = "Path #{path} not defined"
        @status = HTTP::Status::NOT_FOUND
        @source = path
      end

      def render(template : String, data)
        templates.load("#{template}").render(data)
      end
    end
  end
end
