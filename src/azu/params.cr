require "http"
require "json"
require "./params/**"

module Azu
  class Params
    CONTENT_TYPE     = "Content-Type"
    URL_ENCODED_FORM = "application/x-www-form-urlencoded"
    MULTIPART_FORM   = "multipart/form-data"
    APPLICATION_JSON = "application/json"

    getter files = Hash(String, Multipart::File).new
    getter query : HTTP::Params
    getter form : HTTP::Params
    getter path : = Hash(String, String).new

    def initialize(request : HTTP::Request)
      @query = request.query_params
      @path = path

      case request.content_type.sub_type
      when "x-www-form-urlencoded" then @form = ParamsForm.parse(request)
      when "form-data"             then @form, @files = Multipart.parse(request)
      else                              @form = HTTP::Params.new
      end
    end
  end
end
