require "http"
require "json"

module Azu
  class Params
    CONTENT_TYPE     = "Content-Type"
    URL_ENCODED_FORM = "application/x-www-form-urlencoded"
    MULTIPART_FORM   = "multipart/form-data"
    APPLICATION_JSON = "application/json"

    getter files = Hash(String, Multipart::File).new
    getter query : HTTP::Params
    getter form : HTTP::Params
    getter path : Hash(String, String)

    def initialize(request : HTTP::Request)
      @query = request.query_params
      @path = request.path_params
      
      case request.content_type.sub_type
      when "x-www-form-urlencoded" then @form = Form.parse(request)
      when "form-data"             then @form, @files = Multipart.parse(request)
      else                              @form = HTTP::Params.new
      end
    end

    def [](key)
      (form[key]? || path[key]? || query[key]?).not_nil!
    end

    def []?(key)
      form[key]? || path[key]? || query[key]?
    end

    def fetch_all(key)
      return form.fetch_all(key) if form.has_key? key
      return [path[key]] if path.has_key? key
      query.fetch_all(key)
    end

    def each
      to_h.each do |k, v|
        yield k, v
      end
    end

    def to_h
      hash = Hash(String, String).new
      hash.merge! query.to_h
      hash.merge! path
      hash.merge! form.to_h
      hash
    end

    module Multipart
      struct File
        getter file : ::File
        getter filename : String?
        getter headers : HTTP::Headers
        getter creation_time : Time?
        getter modification_time : Time?
        getter read_time : Time?
        getter size : UInt64?

        def initialize(upload)
          @filename = upload.filename
          @file = ::File.tempfile(filename)
          ::File.open(@file.path, "w") do |f|
            ::IO.copy(upload.body, f)
          end
          @headers = upload.headers
          @creation_time = upload.creation_time
          @modification_time = upload.modification_time
          @read_time = upload.read_time
          @size = upload.size
        end
      end

      def self.parse(request : HTTP::Request)
        multipart_params = HTTP::Params.new
        files = Hash(String, Multipart::File).new

        HTTP::FormData.parse(request) do |upload|
          next unless upload
          filename = upload.filename
          if filename.is_a?(String) && !filename.empty?
            files[upload.name] = File.new(upload: upload)
          else
            multipart_params[upload.name] = upload.body.gets_to_end
          end
        end
        {multipart_params, files}
      end
    end

    module Form
      def self.parse(request : HTTP::Request)
        parse_part(request.body)
      end

      def self.parse_part(input : IO) : HTTP::Params
        HTTP::Params.parse(input.gets_to_end)
      end

      def self.parse_part(input : String) : HTTP::Params
        HTTP::Params.parse(input)
      end

      def self.parse_part(input : Nil) : HTTP::Params
        HTTP::Params.parse("")
      end
    end
  end
end
