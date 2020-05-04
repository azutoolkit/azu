module Azu
  class Error < Exception
    getter env : Environment = ENVIRONMENT
    getter log : ::Log = CONFIG.log
    property status : Int32 = 500
    property title : String = "Internal Server Error"
    property detail : String = "Internal Server Error"
    property source : String = ""
    property errors : Array(String)? = nil

    def initialize(@detail = "", @source = "", @errors = Array(String).new)
    end

    def self.from_exception(ex)
      new detail: ex.message.not_nil!
    end

    def link
      "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status}"
    end

    def to_json
      {
        status: status,
        link:   link,
        title:  title,
        detail: detail,
        errors: errors,
        source: source,
      }.to_json
    end

    def print_log
      log.error { "#{status}: #{title}" }
      errors.not_nil!.each { |e| log.error { e } }
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
