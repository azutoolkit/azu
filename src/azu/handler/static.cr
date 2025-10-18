require "mime"

module Azu
  module Handler
    class Static < HTTP::StaticFileHandler
      ZIPPED_FILE_EXTENSIONS = %w(.htm .html .txt .css .js .svg .json .xml .otf .ttf .woff .woff2)

      MIME.register(".collection", "font/collection")
      MIME.register(".otf", "font/otf")
      MIME.register(".sfnt", "font/sfnt")
      MIME.register(".ttf", "font/ttf")
      MIME.register(".woff", "font/woff")
      MIME.register(".woff2", "font/woff2")
      MIME.register(".js", "text/javascript")
      MIME.register(".png", "text/javascript")
      MIME.register(".map", "application/json")

      def initialize(public_dir : String = "public", fallthrough = false, directory_listing = false)
        super
      end

      def call(context : HTTP::Server::Context)
        return allow_get_or_head(context) unless method_get_or_head?(context.request.method)

        original_path = context.request.path || ""
        request_path = URI.decode(original_path)

        return handle_invalid_path(context) unless valid_path?(original_path, request_path)

        path_info = resolve_path_info(original_path, request_path)
        return handle_directory_request(context, path_info) if path_info.is_dir_path && File.exists?(path_info.root_file)
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
        return if etag(context, path_info.root_file)
        serve_file(context, path_info.root_file)
      end

      private def should_redirect?(request_path : String, path_info : PathInfo) : Bool
        is_dir_path = Dir.exists?(path_info.file_path) && !path_info.is_dir_path
        request_path != File.expand_path(request_path, "/") || is_dir_path
      end

      private def handle_redirect(context : HTTP::Server::Context, request_path : String, path_info : PathInfo)
        is_dir_path = Dir.exists?(path_info.file_path) && !path_info.is_dir_path
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
          return if etag(context, file_path)
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
        env.response.headers["Cache-Control"] = "private, max-age=3600"
        minsize = 860 # http://webmasters.stackexchange.com/questions/31750/what-is-recommended-minimum-object-size-for-gzip-performance-benefits ??
        request_headers = env.request.headers
        filesize = File.size(file_path)
        File.open(file_path) do |file|
          next multipart(file, env) if next_multipart?(env)

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

      private def next_multipart?(env)
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

      private def multipart(file, env)
        fileb = file.size

        range = env.request.headers["Range"]
        match = range.match(/bytes=(\d{1,})-(\d{0,})/)

        startb = 0
        endb = 0

        if match
          if match.size >= 2
            startb = match[1].to_i { 0 }
          end

          if match.size >= 3
            endb = match[2].to_i { 0 }
          end
        end

        if endb == 0
          endb = fileb - 1
        end

        if startb < endb && endb < fileb
          content_length = 1 + endb - startb
          env.response.status_code = 206
          env.response.content_length = content_length
          env.response.headers["Accept-Ranges"] = "bytes"
          env.response.headers["Content-Range"] = "bytes #{startb}-#{endb}/#{fileb}" # MUST

          if startb > 1024
            skipped = 0
            # file.skip only accepts values less or equal to 1024 (buffer size, undocumented)
            until skipped + 1024 > startb
              file.skip(1024)
              skipped += 1024
            end
            if skipped - startb > 0
              file.skip(skipped - startb)
            end
          else
            file.skip(startb)
          end

          IO.copy(file, env.response, content_length)
        else
          env.response.content_length = fileb
          env.response.status_code = 200 # Range not satisfiable, see 4.4 Note
          IO.copy(file, env.response)
        end
      end
    end
  end
end
