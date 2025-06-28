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
      @form = HTTP::Params.new

      case request.content_type.sub_type
      when "json"
        @json = request.body.not_nil!.gets_to_end
      when "x-www-form-urlencoded"
        @form = Form.parse(request)
      when "form-data"
        @form, @files = Multipart.parse(request)
      else
        @form = HTTP::Params.new
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

    def to_query
      String.build do |s|
        to_h.each do |key, value|
          s << key << "=" << value << "&"
        end
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
          temp_filename += "_#{@filename}" if @filename && !@filename.not_nil!.empty?
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
                raise FileUploadError.new(
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
              # Read non-file form data with size limit
              body_content = upload.body.gets_to_end
              if body_content.bytesize > CONFIG.upload.max_file_size
                raise FileUploadError.new(
                  "Form field '#{upload.name}' exceeds maximum size limit",
                  field_name: upload.name
                )
              end
              multipart_params[upload.name] = body_content
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
        # Add size limit for form data
        content = input.gets_to_end
        if content.bytesize > CONFIG.upload.max_file_size
          raise FileUploadError.new("Form data exceeds maximum allowed size")
        end
        HTTP::Params.parse(content)
      end

      def self.parse_part(input : String) : HTTP::Params
        if input.bytesize > CONFIG.upload.max_file_size
          raise FileUploadError.new("Form data exceeds maximum allowed size")
        end
        HTTP::Params.parse(input)
      end

      def self.parse_part(input : Nil) : HTTP::Params
        HTTP::Params.parse("")
      end
    end
  end
end
