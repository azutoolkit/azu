require "ecr"
require "./response"

module Azu
  class Error < Exception
    include Azu::Response

    getter env : Environment = ENVIRONMENT
    getter log : ::Log = CONFIG.log
    property status : Int32 = 500
    property title : String = "Internal Server Error"
    property detail : String = "Internal Server Error"
    property source : String = ""
    property errors : Array(String) = [] of String

    def initialize(@detail = "", @source = "", @errors = Array(String).new)
    end

    def self.from_exception(ex)
      new detail: ex.message.not_nil!
    end

    def link
      "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status}"
    end

    def html
      ECR.render "./src/azu/template/error.ecr"
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
    getter status : Int32 = 400
  end

  class NotFound < Error
    getter title = "Not found"
    getter status : Int32 = 404

    def initialize(path : String)
      @detail = "Path #{path} not defined"
      @source = path
    end
  end
end
