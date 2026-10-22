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

    def [](key)
      form[key]? || path[key]? || query[key]? || raise KeyError.new("Missing parameter: #{key}")
    end

    def []?(key)
      form[key]? || path[key]? || query[key]?
    end

    def fetch_all(key)
      return form.fetch_all(key) if form.has_key? key
      return [path[key]] if path.has_key? key
      query.fetch_all(key)
    end

    def each(&)
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

    # The merged parameters as a URL-encoded query string.
    def to_query : String
      HTTP::Params.encode(to_h)
    end

    # Builds the typed request with the standard library's `from_json` and
    # `URI::Params::Serializable.from_www_form`. Input that cannot become a `Request`
    # is the client's mistake, so it is answered with 400 rather than a server error.
    def typed_request : Request
      if body = json
        Request.from_json body
      else
        Request.from_www_form to_query
      end
    rescue ex : JSON::ParseException | URI::SerializableError | Time::Format::Error | ArgumentError
      raise Response::BadRequest.new(ex.message.to_s)
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

        case request.content_type.sub_type
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
      end

      # An oversized body is refused after at most limit + 1 bytes, instead of buffering all of it first.
      def self.read(io : IO) : String
        limit = CONFIG.upload.max_file_size
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
          CONFIG.upload.prepare
          @temp_path = Path[CONFIG.upload.temp_dir, temp_filename].to_s

          # Create temp file and stream upload data
          @file = ::File.new(@temp_path, "w+")
          stream_upload_data(upload.body)
        end

        private def stream_upload_data(source_io : IO)
          buffer = Bytes.new(CONFIG.upload.buffer_size)
          total_bytes = 0_u64
          max_size = CONFIG.upload.max_file_size

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
              Fiber.yield if total_bytes % (CONFIG.upload.buffer_size * 10) == 0
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
        raise TooLarge.new("Form data exceeds maximum allowed size") if input.bytesize > CONFIG.upload.max_file_size
        HTTP::Params.parse(input)
      end

      def self.parse_part(input : Nil) : HTTP::Params
        HTTP::Params.parse("")
      end
    end
  end
end
