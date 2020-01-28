module Azu
  class Error(Code) < Exception
    getter status : Int32 = Code
    getter link : String = "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{Code}"
    getter title : String
    getter detail : String
    getter source : String

    def initialize(@title, @detail = "", @source = Hash(Symbold, String).new)
    end
  end
end
