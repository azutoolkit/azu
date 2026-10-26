require "http"
require "json"

module Azu
  class Params(Request)
    CONTENT_TYPE     = "Content-Type"
    URL_ENCODED_FORM = "application/x-www-form-urlencoded"
    MULTIPART_FORM   = "multipart/form-data"
    APPLICATION_JSON = "application/json"

    getter files = Hash(String, Multipart::File).new
    getter query : HTTP::Params
    getter form : HTTP::Params
    getter path : Hash(String, String)
    getter json : String? = nil

    def initialize(request : HTTP::Request)
      @query = request.query_params
      @path = request.path_params
      @form, @files, @json = Body.parse(request)
    end

    # A parameter is looked up in the path, then the query string, then the body: what the URL addresses cannot be
    # changed by a body field of the same name (`POST /users/5` with `id=1` is user 5).
    def [](key)
      self[key]? || raise KeyError.new("Missing parameter: #{key}")
    end

    def []?(key)
      path[key]? || query[key]? || form[key]?
    end

    def fetch_all(key)
      return [path[key]] if path.has_key? key
      return query.fetch_all(key) if query.has_key? key
      form.fetch_all(key)
    end

    def each(&)
      to_h.each do |k, v|
        yield k, v
      end
    end

    def to_h
      hash = Hash(String, String).new
      hash.merge! form.to_h
      hash.merge! query.to_h
      hash.merge! path
      hash
    end

    # The merged parameters as a URL-encoded query string.
    def to_query : String
      HTTP::Params.encode(to_h)
    end

    # Builds the typed request with the standard library's `from_json` and
    # `URI::Params::Serializable.from_www_form`. Input that cannot become a `Request`
    # is the client's mistake, so it is answered with 400 rather than a server error.
    def typed_request : Request
      if body = json
        Request.from_json json_with_url_overrides(body)
      else
        Request.from_www_form to_query
      end
    rescue ex : JSON::Error | URI::SerializableError | Time::Format::Error | ArgumentError
      raise Response::BadRequest.new(ex.message.to_s)
    end

    # The path and the query string win over the body, as for forms. A JSON body is the contract's input, so a key
    # the URL also names is replaced there, keeping the JSON type the body gave it (a number stays a number when the
    # URL value is one). Keys the body does not have are not added: a JSON contract declares what it takes from the
    # body, and only top-level keys are replaced (`{"x":{"id":2}}` keeps `x.id`). Keys are compared decoded
    # (`"\u0069d"` is `id`), a key renamed with `@[JSON::Field(key:)]` is matched by the URL parameter named like the
    # field, and a body in which no key matches is returned as it came (one scan, nothing built). Otherwise the body is
    # rewritten with the same values: numbers keep their raw text (integers beyond Int64, float notation), strings and
    # nested values are re-serialized as equivalent JSON.
    private def json_with_url_overrides(body : String) : String
      return body if path.empty? && query.empty?
      overrides = url_overrides
      return body unless json_object_names_any?(body, overrides)

      pull = JSON::PullParser.new(body)
      JSON.build do |json|
        json.object do
          pull.read_object do |key|
            if value = overrides[key]?
              kind = pull.kind
              pull.skip
              json.field(key) { write_same_type(json, value, kind) }
            else
              json.field(key) { pull.read_raw(json) }
            end
          end
        end
      end
    end

    # :nodoc: for specs
    def json_with_url_overrides_for_spec(body : String) : String
      json_with_url_overrides(body)
    end

    # URL parameters by the JSON key they replace. When `?user_name=` and `?name=` both target a field renamed to
    # `user_name`, the real field name (`name`) wins; within a name the path wins over the query.
    private def url_overrides : Hash(String, String)
      overrides = Hash(String, String).new
      {false, true}.each do |renamed|
        {query.to_h, path}.each do |source|
          source.each do |name, value|
            key = json_key(name)
            overrides[key] = value if (key != name) == renamed
          end
        end
      end
      overrides
    end

    private def json_object_names_any?(body : String, names : Hash(String, String)) : Bool
      pull = JSON::PullParser.new(body)
      return false unless pull.kind.begin_object?
      pull.read_object do |key|
        return true if names.has_key?(key)
        pull.skip
      end
      false
    end

    # The JSON key of the contract field named `name` (its `@[JSON::Field(key:)]`, else the name itself).
    private def json_key(name : String) : String
      {% begin %}
        {% if Request.is_a?(TypeNode) && !Request.instance_vars.empty? %}
          case name
          {% for ivar in Request.instance_vars %}
            {% ann = ivar.annotation(::JSON::Field) %}
            {% if ann && ann[:key] %}
          when {{ ivar.name.stringify }} then {{ ann[:key] }}.to_s
            {% end %}
          {% end %}
          else name
          end
        {% else %}
          name
        {% end %}
      {% end %}
    end

    # Writes the URL `value` as the JSON type `like` the body used; a value that is not one (`abc` for a number, a
    # non-finite float) stays a string, which the contract then refuses.
    private def write_same_type(json : JSON::Builder, value : String, like : JSON::PullParser::Kind) : Nil
      case like
      when .int?
        (number = value.to_i64?) ? json.number(number) : json.string(value)
      when .float?
        number = value.to_f64?
        number && number.finite? ? json.number(number) : json.string(value)
      when .bool?
        value == "true" || value == "false" ? json.bool(value == "true") : json.string(value)
      else
        json.string(value)
      end
    end

    # Custom exception for file upload errors
    class FileUploadError < Exception
      getter field_name : String?
      getter filename : String?

      def initialize(message : String, @field_name : String? = nil, @filename : String? = nil)
        super(message)
      end
    end

    # Raised when a request body or upload goes over the configured size limit
    class TooLarge < FileUploadError
    end

    # Reads request bodies through the configured size limit.
    module Body
      # Parses the body by content type into its form, uploaded files and raw JSON.
      # A body that is too large is answered with 413, any other unreadable one with 400.
      def self.parse(request : HTTP::Request) : {HTTP::Params, Hash(String, Multipart::File), String?}
        no_files = Hash(String, Multipart::File).new

        # Without a Content-Type there is no body format to parse; this skips building the "text/plain" default
        sub_type = request.content_type.sub_type if format?(request)
        case sub_type
        when "json"
          {HTTP::Params.new, no_files, request.body.try { |body| read(body) }}
        when "x-www-form-urlencoded"
          {Form.parse(request), no_files, nil}
        when "form-data"
          form, files = Multipart.parse(request)
          {form, files, nil}
        else
          {HTTP::Params.new, no_files, nil}
        end
      rescue ex : TooLarge
        raise Response::PayloadTooLarge.new(ex.message.to_s)
      rescue ex : FileUploadError
        raise Response::BadRequest.new(ex.message.to_s)
      rescue MIME::Error
        raise Response::BadRequest.new("Malformed Content-Type header")
      end

      # :nodoc:
      #
      # A body is parsed only when a Content-Type names its format.
      def self.format?(request : HTTP::Request) : Bool
        request.headers.has_key?("Content-Type")
      end

      # An oversized body is refused after at most limit + 1 bytes, instead of buffering all of it first.
      def self.read(io : IO) : String
        limit = Azu.current_config.upload.max_file_size
        content = IO::Sized.new(io, read_size: limit.to_i64 + 1).gets_to_end
        raise TooLarge.new("Request body exceeds maximum allowed size") if content.bytesize > limit
        content
      end
    end

    module Multipart
      class File
        getter file : ::File
        getter filename : String?
        getter headers : HTTP::Headers
        getter creation_time : Time?
        getter modification_time : Time?
        getter read_time : Time?
        getter size : UInt64?
        getter temp_path : String

        def initialize(upload)
          @filename = upload.filename
          @headers = upload.headers
          @creation_time = upload.creation_time
          @modification_time = upload.modification_time
          @read_time = upload.read_time
          @size = upload.size

          # Generate unique temp file path
          timestamp = Time.utc.to_unix_ms
          random_suffix = Random.rand(999999)
          temp_filename = "azu_upload_#{timestamp}_#{random_suffix}"
          temp_filename += "_#{@filename}" if @filename && !@filename.try(&.empty?)
          upload_config = Azu.current_config.upload
          upload_config.prepare
          @temp_path = Path[upload_config.temp_dir, temp_filename].to_s

          # Create temp file and stream upload data
          @file = ::File.new(@temp_path, "w+")
          stream_upload_data(upload.body, upload_config)
        end

        private def stream_upload_data(source_io : IO, upload_config : UploadConfiguration)
          buffer = Bytes.new(upload_config.buffer_size)
          total_bytes = 0_u64
          max_size = upload_config.max_file_size

          begin
            while (bytes_read = source_io.read(buffer)) > 0
              total_bytes += bytes_read.to_u64

              # Check size limit
              if total_bytes > max_size
                raise TooLarge.new(
                  "File size exceeds maximum allowed size of #{max_size} bytes",
                  filename: @filename
                )
              end

              # Write buffer to temp file
              @file.write(buffer[0, bytes_read])

              # Yield to other fibers periodically for non-blocking behavior
              Fiber.yield if total_bytes % (upload_config.buffer_size * 10) == 0
            end

            # Flush and rewind file for reading
            @file.flush
            @file.rewind

            # Update size with actual written bytes
            @size = total_bytes
          rescue ex : FileUploadError
            # Clean up temp file on error
            cleanup_temp_file
            raise ex
          rescue ex
            # Clean up temp file on unexpected error
            cleanup_temp_file
            raise FileUploadError.new(
              "Failed to process uploaded file: #{ex.message}",
              filename: @filename
            )
          end
        end

        # Clean up the temporary file
        def cleanup
          cleanup_temp_file
        end

        private def cleanup_temp_file
          if @file && !@file.closed?
            @file.close rescue nil
          end

          if ::File.exists?(@temp_path)
            ::File.delete(@temp_path) rescue nil
          end
        end

        # Finalizer to ensure cleanup
        def finalize
          cleanup_temp_file
        end
      end

      def self.parse(request : HTTP::Request)
        multipart_params = HTTP::Params.new
        files = Hash(String, Multipart::File).new

        begin
          HTTP::FormData.parse(request) do |upload|
            next unless upload
            filename = upload.filename
            if filename.is_a?(String) && !filename.empty?
              begin
                files[upload.name] = File.new(upload: upload)
              rescue ex : FileUploadError
                # Log the error and continue processing other uploads
                Log.for("Azu::Params::Multipart").error(exception: ex) {
                  "Failed to process upload for field '#{upload.name}': #{ex.message}"
                }
                # Re-raise for now - you might want to collect errors and continue
                raise ex
              end
            else
              multipart_params[upload.name] = Body.read(upload.body)
            end
          end
        rescue ex : FileUploadError
          # Clean up any successfully created files
          files.each_value(&.cleanup)
          raise ex
        rescue ex : IO::TimeoutError
          # The client stopped sending: not a malformed form (`Rescuer` answers 408).
          files.each_value(&.cleanup)
          raise ex
        rescue ex
          # Clean up any successfully created files
          files.each_value(&.cleanup)
          raise FileUploadError.new("Failed to parse multipart form data: #{ex.message}")
        end

        {multipart_params, files}
      end
    end

    module Form
      def self.parse(request : HTTP::Request)
        parse_part(request.body)
      end

      def self.parse_part(input : IO) : HTTP::Params
        HTTP::Params.parse(Body.read(input))
      end

      def self.parse_part(input : String) : HTTP::Params
        raise TooLarge.new("Form data exceeds maximum allowed size") if input.bytesize > Azu.current_config.upload.max_file_size
        HTTP::Params.parse(input)
      end

      def self.parse_part(input : Nil) : HTTP::Params
        HTTP::Params.parse("")
      end
    end
  end
end
