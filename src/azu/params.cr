require "http"
require "json"
require "./params/**"

module Azu
  module Types
    alias Files = Hash(String, Multipart::File)
    alias Params = Hash(String, String)
  end

  class Params
    CONTENT_TYPE     = "Content-Type"
    URL_ENCODED_FORM = "application/x-www-form-urlencoded"
    MULTIPART_FORM   = "multipart/form-data"
    APPLICATION_JSON = "application/json"

    getter files = Types::Files.new
    getter query : HTTP::Params
    getter path : Hash(String, String)
    getter form : HTTP::Params | Hash(String, Multipart::File) | Hash(String, String) | JSON::Any

    def initialize(request : HTTP::Request)
      @query = request.query_params
      @path = request.route.not_nil!.params

      case request.content_type.sub_type
      when "x-www-form-urlencoded" then @form = ParamsForm.parse(request)
      when "form-data"             then @form, @files = Multipart.parse(request)
      else                              @form = Hash(String, String).new
      end
    end
  end
end
