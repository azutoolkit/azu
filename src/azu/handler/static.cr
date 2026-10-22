require "mime"

module Azu
  module Handler
    class Static < HTTP::StaticFileHandler
      ZIPPED_FILE_EXTENSIONS = %w(.htm .html .txt .css .js .svg .json .xml .otf .ttf .woff .woff2)

      # A single byte range: `bytes=first-last`, `bytes=first-` or `bytes=-suffix`
      RANGE_HEADER = /\Abytes=(\d*)-(\d*)\z/

      # A content hash in the file name (`app-3f2a9c1b.css`, `logo.8c1d0e5f.png`): the name
      # changes whenever the content does, so the file may be cached for as long as wanted.
      # The hash has at least one letter, so a date (`report-20240101.pdf`) is not one.
      FINGERPRINTED = /[-.](?=[0-9]*[a-f])[0-9a-f]{8,}(?:\.[a-z0-9]+)+\z/i

      MIME.register(".collection", "font/collection")
      MIME.register(".otf", "font/otf")
      MIME.register(".sfnt", "font/sfnt")
      MIME.register(".ttf", "font/ttf")
      MIME.register(".woff", "font/woff")
      MIME.register(".woff2", "font/woff2")
      MIME.register(".js", "text/javascript")
      MIME.register(".png", "image/png")
      MIME.register(".map", "application/json")

      # Files with a fingerprint are cached for `cache_max_age` seconds and never revalidated;
      # every other file is sent with `cache_control`, which by default makes caches revalidate
      # it with the ETag on each use, so a deploy is never served stale.
      def initialize(
        public_dir : String = "public",
        fallthrough = false,
        directory_listing = false,
        @cache_control : String = "public, no-cache",
        cache_max_age : Int32 = CONFIG.assets.cache_max_age,
      )
        super(public_dir, fallthrough, directory_listing)
        @fingerprinted_cache_control = "public, max-age=#{cache_max_age}, immutable"
      end

      def call(context : HTTP::Server::Context)
        return allow_get_or_head(context) unless method_get_or_head?(context.request.method)

        original_path = context.request.path || ""
        request_path = URI.decode(original_path)

        return handle_invalid_path(context) unless valid_path?(original_path, request_path)

        path_info = resolve_path_info(original_path, request_path)
        return handle_directory_request(context, path_info) if path_info.is_dir_path? && File.exists?(path_info.root_file)
        return handle_redirect(context, request_path, path_info) if should_redirect?(request_path, path_info)

        call_next_with_file_path(context, request_path, path_info.file_path)
      end

      private def valid_path?(original_path : String, request_path : String) : Bool
        return false if original_path.includes?('\0') || request_path.includes?('\0')
        true
      end

      private def handle_invalid_path(context : HTTP::Server::Context)
        context.response.status_code = 400
        context.response.print "Bad Request: Invalid path"
        context.response.close
      end

      private struct PathInfo
        getter file_path : String
        getter root_file : String
        getter? is_dir_path : Bool

        def initialize(@file_path : String, @root_file : String, @is_dir_path : Bool)
        end
      end

      private def resolve_path_info(original_path : String, request_path : String) : PathInfo
        is_dir_path = dir_path?(original_path)
        expanded_path = File.expand_path(request_path, "/")
        expanded_path += "/" if is_dir_path && !dir_path?(expanded_path)
        is_dir_path = dir_path?(expanded_path)
        file_path = File.join(@public_dir, expanded_path)
        root_file = "#{@public_dir}#{expanded_path}index.html"
        PathInfo.new(file_path, root_file, is_dir_path)
      end

      private def handle_directory_request(context : HTTP::Server::Context, path_info : PathInfo)
        return if not_modified?(context, path_info.root_file)
        serve_file(context, path_info.root_file)
      end

      private def should_redirect?(request_path : String, path_info : PathInfo) : Bool
        is_dir_path = Dir.exists?(path_info.file_path) && !path_info.is_dir_path?
        request_path != File.expand_path(request_path, "/") || is_dir_path
      end

      private def handle_redirect(context : HTTP::Server::Context, request_path : String, path_info : PathInfo)
        is_dir_path = Dir.exists?(path_info.file_path) && !path_info.is_dir_path?
        expanded_path = File.expand_path(request_path, "/")
        redirect_to context, file_redirect_path(expanded_path, is_dir_path)
      end

      private def dir_path?(path)
        path.ends_with? "/"
      end

      private def method_get_or_head?(method)
        method == "GET" || method == "HEAD"
      end

      private def allow_get_or_head(context)
        if @fallthrough
          call_next(context)
        else
          context.response.status_code = 405
          context.response.headers.add("Allow", "GET, HEAD")
        end

        nil
      end

      private def file_redirect_path(path, is_dir_path)
        "#{path}/#{is_dir_path ? "/" : ""}"
      end

      private def call_next_with_file_path(context, request_path, file_path)
        config = static_config

        if Dir.exists?(file_path)
          if config["dir_listing"]
            context.response.content_type = "text/html"
            directory_listing(context.response, Path[request_path], Path[file_path])
          elsif @fallthrough
            call_next(context)
          else
            context.response.status_code = 404
          end
        elsif File.exists?(file_path)
          return if not_modified?(context, file_path)
          serve_file(context, file_path)
        elsif @fallthrough
          call_next(context)
        else
          context.response.status_code = 404
        end
      end

      private def static_config
        {"dir_listing" => @directory_listing, "gzip" => true}
      end

      # Sends the caching headers of a file, then answers 304 when the client's copy is current.
      # `Vary` is needed because a shared cache may now store the response, and it is stored
      # compressed or not depending on the request.
      private def not_modified?(context, file_path : String) : Bool
        headers = context.response.headers
        headers["Cache-Control"] = FINGERPRINTED.matches?(file_path) ? @fingerprinted_cache_control : @cache_control
        headers["Vary"] = "Accept-Encoding"
        etag(context, file_path)
      end

      private def etag(context, file_path)
        etag = %{W/"#{File.info(file_path).modification_time.to_unix}"}
        context.response.headers["ETag"] = etag
        return false if !context.request.headers["If-None-Match"]? || context.request.headers["If-None-Match"] != etag
        context.response.headers.delete "Content-Type"
        context.response.content_length = 0
        context.response.status_code = 304 # not modified
        true
      end

      private def mime_type(path)
        MIME.from_filename path
      end

      private def serve_file(env, path : String, mime_type : String? = nil)
        config = static_config
        file_path = File.expand_path(path, Dir.current)
        mime_type ||= mime_type(file_path)
        env.response.content_type = mime_type
        env.response.headers["Accept-Ranges"] = "bytes"
        env.response.headers["X-Content-Type-Options"] = "nosniff"
        minsize = 860 # http://webmasters.stackexchange.com/questions/31750/what-is-recommended-minimum-object-size-for-gzip-performance-benefits ??
        request_headers = env.request.headers
        filesize = File.size(file_path)
        File.open(file_path) do |file|
          next serve_range(file, env) if range_request?(env)

          if request_headers.includes_word?("Accept-Encoding", "gzip") && config_gzip?(config) && filesize > minsize && zip_file?(file_path)
            gzip_encoding(env, file)
          elsif request_headers.includes_word?("Accept-Encoding", "deflate") && config_gzip?(config) && filesize > minsize && zip_file?(file_path)
            deflate_endcoding(env, file)
          else
            env.response.content_length = filesize
            IO.copy(file, env.response)
          end
        end
        return
      end

      private def zip_file?(path)
        ZIPPED_FILE_EXTENSIONS.includes? File.extname(path)
      end

      private def range_request?(env)
        env.request.method == "GET" && env.request.headers.has_key?("Range")
      end

      private def config_gzip?(config)
        config["gzip"]?
      end

      private def gzip_encoding(env, file)
        env.response.headers["Content-Encoding"] = "gzip"
        Compress::Gzip::Writer.open(env.response) do |deflate|
          IO.copy(file, deflate)
        end
      end

      private def deflate_endcoding(env, file)
        env.response.headers["Content-Encoding"] = "deflate"
        Compress::Deflate::Writer.open(env.response) do |deflate|
          IO.copy(file, deflate)
        end
      end

      # A byte range resolved against the size of the file it applies to
      private record ByteRange, first : Int64, last : Int64 do
        def length : Int64
          last - first + 1
        end

        def satisfiable? : Bool
          length > 0
        end
      end

      # Serves the requested byte range (RFC 7233): 206 with exactly those bytes, 416 when the
      # range lies past the end, or the whole file when the header is not a range we understand.
      private def serve_range(file, env)
        size = file.size
        return send_whole(file, env) unless range = byte_range(env.request.headers["Range"], size)

        if range.satisfiable?
          env.response.status_code = 206
          env.response.headers["Content-Range"] = "bytes #{range.first}-#{range.last}/#{size}"
          env.response.content_length = range.length
          file.seek(range.first)
          IO.copy(file, env.response, range.length)
        else
          env.response.status_code = 416
          env.response.headers["Content-Range"] = "bytes */#{size}"
          env.response.content_length = 0
        end
      end

      private def send_whole(file, env)
        env.response.content_length = file.size
        IO.copy(file, env.response)
      end

      # nil means the header is not a single, well-formed byte range (another unit, several
      # ranges, reversed bounds), which a server may ignore. An end past the file is clamped to
      # its last byte; a range that starts past it comes back unsatisfiable.
      private def byte_range(header : String, size : Int64) : ByteRange?
        return unless match = RANGE_HEADER.match(header.strip)
        from, to = match[1], match[2]

        if from.empty?
          return if to.empty?
          suffix = to.to_i64? || size
          return ByteRange.new(Math.max(size - suffix, 0_i64), size - 1)
        end

        first = from.to_i64? || return
        requested_last = to.to_i64? || Int64::MAX
        return if requested_last < first

        ByteRange.new(first, Math.min(requested_last, size - 1))
      end
    end
  end
end
