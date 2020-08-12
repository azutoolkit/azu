require "ecr"
require "./response"

module Azu
  class Error < Exception
    include Azu::Response

    getter env : Environment = ENVIRONMENT
    getter log : ::Log = CONFIG.log
    property status : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR
    property title : String = "Internal Server Error"
    property detail : String = "Internal Server Error"
    property source : String = ""
    property errors : Array(String) = [] of String
    getter templates : Templates = CONFIG.templates

    def initialize(@detail = "", @source = "", @errors = Array(String).new)
    end

    def self.from_exception(ex)
      new detail: ex.message.not_nil!
    end

    def link
      "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status}"
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

    def print_log
      log.error { "#{status}: #{title}" }
      errors.each { |e| log.error { e } }
      log.error { "Source: #{source}" } if source
      log.error { "Detail: #{detail}" } if detail
      log.error { inspect_with_backtrace } if env.development?
    end
  end

  class BadRequest < Error
    getter title = "Bad Request"
    getter status : HTTP::Status = HTTP::Status::BAD_REQUEST
  end

  class NotFound < Error
    getter title = "Not found"
    getter status : HTTP::Status = HTTP::Status::NOT_FOUND

    def initialize(path : String)
      @detail = "Path #{path} not defined"
      @source = path
    end

    def render(template : String, data)
      templates.load("#{Templates::ERROR_PATH_KEY}/#{template}").render(data)
    end
  end
end
