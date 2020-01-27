require "http"
require "json"
require "./params/**"

module Azu
  module Types
    alias Key = String | Symbol
    alias Files = Hash(String, Multipart::File)
    alias Params = Hash(String, String)
  end

  class Params
    class InvalidParam < Exception
    end

    URL_ENCODED_FORM = "application/x-www-form-urlencoded"
    MULTIPART_FORM   = "multipart/form-data"
    APPLICATION_JSON = "application/json"

    getter files = Types::Files.new
    getter query : HTTP::Params
    getter path : Hash(String, String)
    getter params : HTTP::Params | Hash(String, Multipart::File) | Hash(String, String) | Nil

    def initialize(request : HTTP::Request)
      @query = request.query_params
      @path = request.route.not_nil!.params

      case request.headers["Content-Type"]? || ""
      when .starts_with?(APPLICATION_JSON) then @params = ParamsJson.parse(request)
      when .starts_with?(URL_ENCODED_FORM) then @params = ParamsForm.parse(request)
      when .starts_with?(MULTIPART_FORM) then @params, @files = Multipart.parse(request)
      else @params = Hash(String, String).new
      end
    end

    def [](key : Types::Key)
      self.[key]? || raise InvalidParam.new(key)
    end

    def []?(key : Types::Key)
      _key = key.to_s
      params.not_nil![key]? || query[key]? || path[key]?
    end

    def has_key?(key : Types::Key) : Bool
      !!self.[key.to_s]?
    end

    def fetch_all(key : Types::Key) : Array
      _key = key.to_s
      if query.has_key?(_key)
        query.fetch_all(_key)
      else
        params.fetch_all(_key)
      end
    end

    def json(key : Types::Key)
      JSON.parse(self[key]?.to_s)
    rescue JSON::ParseException
      raise "Value of params.json(#{key.inspect}) is not JSON!"
    end

    def to_h : Types::Params
      params_hash = Types::Params.new
      query.each { |key, _| params_hash[key] = query[key] }
      form.each { |key, _| params_hash[key] = form[key] }

      path.each_key do |key|
        if value = path[key]
          params_hash[key] = value
        end
      end

      json.each_key { |key| params_hash[key] = json[key].to_s }
      multipart.each_key { |key| params_hash[key] = multipart[key].to_s }
      params_hash
    end
  end
end
