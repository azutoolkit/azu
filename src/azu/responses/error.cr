require "ecr"
require "exception_page"

module Azu
  # :nodoc:
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

      def self.from_exception(ex, status = 500)
        error = new(
          title: ex.message || "Error",
          status: HTTP::Status.from_value(status),
          errors: [] of String
        )
        error.detail=(ex.cause.to_s || "En server error occurred")
        error
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
          status:    status_code,
          link:      link,
          title:     title,
          detail:    detail,
          source:    source,
          errors:    errors,
          backtrace: inspect_with_backtrace,
        }
      end

      def status_code
        status.value
      end

      def render(template : String, data)
        templates.load(template).render(data)
      end

      def xml
        messages = errors.map { |e| "<message>#{e}</message>" }.join("")
        <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <error title="#{title}" status="#{status_code}" link="#{link}">
          <detail>#{detail}</detail>
          <source>#{source}</source>
          <errors>#{messages}</errors>
        </error>
        XML
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

      def to_s(context : HTTP::Server::Context)
        if accept = context.request.accept
          accept.each do |a|
            context.response << case a.sub_type.not_nil!
            when .includes?("html")  then html(context)
            when .includes?("json")  then json
            when .includes?("xml")   then xml
            when .includes?("plain") then text
            else                          text
            end
            break
          end
        end
      end
    end

    class Forbidden < Error
      getter title = "Forbidden"
      getter detail = "The server understood the request but refuses to authorize it."
      getter status : HTTP::Status = HTTP::Status::FORBIDDEN
    end

    class BadRequest < Error
      getter title = "Bad Request"
      getter detail = "The server cannot or will not process the request due to something that is perceived to be a client error."
      getter status : HTTP::Status = HTTP::Status::BAD_REQUEST
    end

    class NotFound < Error
      def initialize(path : String)
        @title = "Not found"
        @detail = "The server can't find the requested resource."
        @status = HTTP::Status::NOT_FOUND
        @source = path
      end

      def render(template : String, data)
        templates.load("#{template}").render(data)
      end
    end
  end
end
