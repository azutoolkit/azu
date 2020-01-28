module Azu
  class Error < Exception
    getter status : Int32 = 500
    getter title : String = name.underscore.gsub("_", " ").capitalize
    getter detail : String = ""
    getter source : String = ""

    def initialize(@detail = "", @source = "")
    end

    def initialize(ex : Exception)
      @detail = ex.message.not_nil!
    end

    def link
      "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status}"
    end

    def to_json
      {
        status: status, 
        link: link, 
        title: title, 
        detail: detail, 
        source: source
    }.to_json
    end
  end

  class MissingParam < Error
    getter title = "Missing params"
    getter status : Int32 = 400
  end

  class InvalidJson < Error
    getter title = "Invalid json"
    getter status : Int32 = 400
  end

  class NotFound < Error
    getter title = "Not found"
    getter status : Int32 = 404
  end

  class NotAcceptable < Error

    getter title = "Not acceptable"
    getter status : Int32 = 406
  end

  class InternalServerError < Error
    getter title = "Internal Server Error"
    getter status : Int32 = 500
  end
end
