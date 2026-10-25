require "mime"

module Azu
  module Handler
    class Static < HTTP::StaticFileHandler
      ZIPPED_FILE_EXTENSIONS = %w(.htm .html .txt .css .js .mjs .svg .json .jsonld .xml .xhtml .csv .vtt .ics .webmanifest .rss .atom .map .eot .otf .ttf .woff .woff2)

      # A single byte range: `bytes=first-last`, `bytes=first-` or `bytes=-suffix`
      RANGE_HEADER = /\Abytes=(\d*)-(\d*)\z/

      # A content hash in the file name (`app-3f2a9c1b.css`, `logo.8c1d0e5f.png`): the name
      # changes whenever the content does, so the file may be cached for as long as wanted.
      # The hash has at least one letter, so a date (`report-20240101.pdf`) is not one.
      FINGERPRINTED = /[-.](?=[0-9]*[a-f])[0-9a-f]{8,}(?:\.[a-z0-9]+)+\z/i

      # How long a public directory that does not exist is believed to stay missing. An application with no
      # `public/` pays no file system calls per request, and one created after boot is served from the next
      # check on.
      MISSING_DIRECTORY_RECHECK = 1.second

      HTML_TYPE = "text/html; charset=utf-8"

      # The content types the handler serves, by lower-case extension. The table is the handler's own and is
      # the same on every host: it never consults the operating system's MIME database (`/etc/mime.types`
      # would add `.sql`, `.yml`, `.md`, `.pem`, `.sh`, `.py`, ... on some hosts) nor the process-wide `MIME`
      # registry. A file whose extension is not here is refused; there is no default type, so a template is
      # never sent as a download. An application adds its own types with `mime_types:`.
      #
      # Crystal's built-in defaults, with Azu's `.js`/`.png` types, fonts and source maps ...
      MIME_TYPES = {
        ".css"        => "text/css; charset=utf-8",
        ".gif"        => "image/gif",
        ".htm"        => "text/html; charset=utf-8",
        ".html"       => "text/html; charset=utf-8",
        ".jpg"        => "image/jpeg",
        ".jpeg"       => "image/jpeg",
        ".js"         => "text/javascript",
        ".json"       => "application/json",
        ".pdf"        => "application/pdf",
        ".png"        => "image/png",
        ".svg"        => "image/svg+xml",
        ".txt"        => "text/plain; charset=utf-8",
        ".xml"        => "text/xml; charset=utf-8",
        ".wasm"       => "application/wasm",
        ".webp"       => "image/webp",
        ".collection" => "font/collection",
        ".otf"        => "font/otf",
        ".sfnt"       => "font/sfnt",
        ".ttf"        => "font/ttf",
        ".woff"       => "font/woff",
        ".woff2"      => "font/woff2",
        ".map"        => "application/json",
        # ... and what a web application serves that those lack: icons, manifests, images, media, captions,
        # feeds, structured data, CSV, calendars, and archives (downloads, never code). Never anything that is
        # source or data of the application itself (templates, `.cr`, `.yml`, `.env`, `.sql`, databases,
        # Markdown, keys and certificates, scripts, executables) and not `.svgz`, which needs
        # `Content-Encoding: gzip`: opt in with `mime_types:`.
        ".ico"         => "image/vnd.microsoft.icon",
        ".webmanifest" => "application/manifest+json",
        ".avif"        => "image/avif",
        ".bmp"         => "image/bmp",
        ".tif"         => "image/tiff",
        ".tiff"        => "image/tiff",
        ".mp4"         => "video/mp4",
        ".webm"        => "video/webm",
        ".mp3"         => "audio/mpeg",
        ".ogg"         => "audio/ogg",
        ".wav"         => "audio/wav",
        ".m4a"         => "audio/mp4",
        ".csv"         => "text/csv; charset=utf-8",
        ".vtt"         => "text/vtt; charset=utf-8",
        ".ics"         => "text/calendar; charset=utf-8",
        ".mjs"         => "text/javascript; charset=utf-8",
        ".eot"         => "application/vnd.ms-fontobject",
        ".rss"         => "application/rss+xml",
        ".atom"        => "application/atom+xml",
        ".jsonld"      => "application/ld+json",
        ".xhtml"       => "application/xhtml+xml",
        ".zip"         => "application/zip",
        ".gz"          => "application/gzip",
        ".tgz"         => "application/gzip",
        ".tar"         => "application/x-tar",
        ".bz2"         => "application/x-bzip2",
        ".xz"          => "application/x-xz",
        ".7z"          => "application/x-7z-compressed",
      }

      # The type of an extensionless file below `/.well-known/` (ACME HTTP-01 challenge tokens)
      WELL_KNOWN_TYPE = "text/plain; charset=utf-8"

      private EXTENSION    = /\A\.[a-z0-9][a-z0-9_+-]*\z/
      private CONTENT_TYPE = %r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*(?:; ?[a-z0-9-]+=[a-z0-9"._-]+)*\z}i

      # Files with a fingerprint are cached for `cache_max_age` seconds and never revalidated;
      # every other file is sent with `cache_control`, which by default makes caches revalidate
      # it with the ETag on each use, so a deploy is never served stale.
      def initialize(
        public_dir : String = "public",
        fallthrough = true,
        directory_listing = false,
        @cache_control : String = "public, no-cache",
        cache_max_age : Int32 = CONFIG.assets.cache_max_age,
        except excluded : Array(String) = [] of String,
        mime_types : Hash(String, String) = {} of String => String,
      )
        super(public_dir, fallthrough, directory_listing)
        @mime_types = MIME_TYPES.merge(normalized_mime_types(mime_types))
        @excluded = excluded.map { |entry| excluded_segments(entry) }
        @fingerprinted_cache_control = "public, max-age=#{cache_max_age}, immutable"
        @clock_origin = Clock.instant
        @public_dir_found = Atomic(Bool).new(false)
        @next_directory_check = Atomic(Int64).new(0_i64)
        public_dir?
      end

      @excluded : Array(Array(String))
      @mime_types : Hash(String, String)

      def call(context : HTTP::Server::Context)
        return allow_get_or_head(context) unless method_get_or_head?(context.request.method)

        original_path = context.request.path || ""
        return call_next(context) if falls_through_early?(original_path)

        request_path = original_path.includes?('%') ? URI.decode(original_path) : original_path

        return handle_invalid_path(context) unless valid_path?(original_path, request_path)

        path_info = resolve_path_info(original_path, request_path)
        return refuse(context) if excluded?(path_info.normalized_path)
        return handle_directory_request(context, path_info) if path_info.is_dir_path? && info(path_info.root_file)

        file_info = info(path_info.file_path)
        if location = redirect_location(request_path, path_info, file_info)
          return redirect_to context, location
        end

        call_next_with_file_path(context, request_path, path_info.file_path, file_info)
      end

      # What is at `path`, nil when nothing is. Nothing can be under a public directory that does not
      # exist, so then the file system is not asked.
      private def info(path : String) : File::Info?
        return unless public_dir?
        File.info?(path)
      rescue IO::Error
        nil
      end

      private def public_dir? : Bool
        return true if @public_dir_found.get
        now = (Clock.instant - @clock_origin).total_nanoseconds.to_i64
        return false if now < @next_directory_check.get

        if Dir.exists?(@public_dir)
          @public_dir_found.set(true)
        else
          @next_directory_check.set(now + MISSING_DIRECTORY_RECHECK.total_nanoseconds.to_i64)
          false
        end
      end

      # With no public directory a plain path can only fall through; decoding and expanding it would allocate.
      private def falls_through_early?(path : String) : Bool
        @fallthrough && !public_dir? && plain_path?(path)
      end

      # A path `call` would neither decode, refuse nor redirect: it has no escape, NUL or backslash (a separator
      # to `except`), no empty or dot segment and no trailing slash, so it is its own normal form. Excluding a
      # trailing slash is conservative: the full lookup of such a path (an `index.html`) falls through as well when
      # nothing is there. One pass, no allocation.
      private def plain_path?(path : String) : Bool
        return path == "/" if dir_path?(path)
        return false unless path.starts_with?('/')

        previous = 0_u8
        path.each_byte do |byte|
          return false if byte === '%' || byte === '\0' || byte === '\\'
          return false if previous === '/' && (byte === '/' || byte === '.')
          previous = byte
        end
        true
      end

      private def valid_path?(original_path : String, request_path : String) : Bool
        return false if original_path.includes?('\0') || request_path.includes?('\0')
        true
      end

      # The segments of a path in its comparable form: backslashes are separators, dot segments are resolved
      # against the root, case and trailing dots or spaces (which some file systems ignore) are dropped.
      private def path_segments(path : String) : Array(String)
        File.expand_path(path.tr("\\", "/"), "/").split('/').compact_map do |segment|
          segment = segment.downcase.rstrip(". ")
          segment unless segment.empty?
        end
      end

      # An entry that resolves to the root (`""`, `"/"`, `"."`, `"/x/.."`) would exclude every path.
      private def excluded_segments(entry : String) : Array(String)
        segments = path_segments(entry)
        raise ArgumentError.new("except entry #{entry.inspect} would exclude every path") if segments.empty?
        segments
      end

      # Whether the resolved path is an `except` entry or lies below one. Whole segments are compared, so
      # `/templates` does not cover `/templates-x`.
      private def excluded?(normalized_path : String) : Bool
        return false if @excluded.empty?
        segments = path_segments(normalized_path)
        @excluded.any? { |entry| segments.size >= entry.size && segments.first(entry.size) == entry }
      end

      # An excluded path is answered as if there were no such file.
      private def refuse(context : HTTP::Server::Context)
        if @fallthrough
          call_next(context)
        else
          context.response.status_code = 404
        end
        nil
      end

      private def handle_invalid_path(context : HTTP::Server::Context)
        Response::BadRequest.new("Invalid path").to_s(context)
        context.response.close
      end

      private struct PathInfo
        getter file_path : String
        getter root_file : String
        getter normalized_path : String
        getter? is_dir_path : Bool

        def initialize(@file_path : String, @root_file : String, @normalized_path : String, @is_dir_path : Bool)
        end
      end

      private def resolve_path_info(original_path : String, request_path : String) : PathInfo
        is_dir_path = dir_path?(original_path)
        normalized_path = File.expand_path(request_path, "/")
        expanded_path = normalized_path
        expanded_path += "/" if is_dir_path && !dir_path?(expanded_path)
        is_dir_path = dir_path?(expanded_path)
        file_path = File.join(@public_dir, expanded_path)
        root_file = "#{@public_dir}#{expanded_path}index.html"
        PathInfo.new(file_path, root_file, normalized_path, is_dir_path)
      end

      private def handle_directory_request(context : HTTP::Server::Context, path_info : PathInfo)
        return if not_modified?(context, path_info.root_file)
        serve_file(context, path_info.root_file, HTML_TYPE)
      end

      # Where to send a request whose path is not in its normal form, or names a directory without the
      # trailing slash; nil when it is served as it is.
      private def redirect_location(request_path : String, path_info : PathInfo, file_info : File::Info?) : String?
        directory_without_slash = !path_info.is_dir_path? && file_info.try(&.directory?) == true
        return unless request_path != path_info.normalized_path || directory_without_slash

        redirect_path(path_info.normalized_path, directory_without_slash)
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
          context.response.headers.add("Allow", "GET, HEAD")
          Response::Error.new("Method Not Allowed", HTTP::Status::METHOD_NOT_ALLOWED, [] of String).to_s(context)
        end

        nil
      end

      # The normal form of the path, ending in one slash for a directory. It starts with exactly one slash: a
      # Location of `//host/...` would be read by a browser as another site.
      private def redirect_path(normalized_path : String, directory : Bool) : String
        path = "/#{normalized_path.lstrip("/\\")}"
        directory && !dir_path?(path) ? "#{path}/" : path
      end

      private def call_next_with_file_path(context, request_path, file_path, file_info : File::Info?)
        if file_info.try(&.directory?)
          if @directory_listing
            context.response.content_type = "text/html"
            directory_listing(context.response, Path[request_path], Path[file_path])
          elsif @fallthrough
            call_next(context)
          else
            context.response.status_code = 404
          end
        elsif file_info
          return refuse(context) unless type = content_type(request_path, file_path)
          return if not_modified?(context, file_path)
          serve_file(context, file_path, type)
        elsif @fallthrough
          call_next(context)
        else
          context.response.status_code = 404
        end
      end

      # Sends the caching headers of a file, then answers 304 when the client's copy is current.
      # `Vary` is needed because a shared cache may now store the response, and it is stored
      # compressed or not depending on the request.
      private def not_modified?(context, file_path : String) : Bool
        headers = context.response.headers
        headers["Cache-Control"] = FINGERPRINTED.matches?(file_path) ? @fingerprinted_cache_control : @cache_control
        # Joined to a Vary another handler set (CORS's Origin), never replacing it.
        Vary.add(headers, "Accept-Encoding")
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

      # The type of the file by its last extension, nil when it is not one the handler serves.
      private def content_type(request_path : String, file_path : String) : String?
        well_known = well_known_segments(request_path)
        return if well_known && !plain_well_known?(well_known)
        extension = File.extname(file_path).downcase
        return @mime_types[extension]? unless extension.empty?
        WELL_KNOWN_TYPE if well_known && !File.basename(file_path).ends_with?('.')
      end

      # The segments below `/.well-known/` of the normalised request path; nil for any other path. The name is
      # compared without regard to case, since a case-insensitive file system resolves `/.Well-Known/` to it.
      private def well_known_segments(request_path : String) : Array(String)?
        segments = File.expand_path(request_path, "/").split('/', remove_empty: true)
        segments[1..] if segments.first?.try(&.downcase) == ".well-known"
      end

      # `/.well-known/<file>` or `/.well-known/<dir>/<file>` (ACME: `acme-challenge/<token>`), no dot name at
      # any level: nothing hidden (`.git/config`, `.env`, `.secrets.json`) and nothing deeper is served from there.
      private def plain_well_known?(segments : Array(String)) : Bool
        (1..2).includes?(segments.size) && segments.none?(&.starts_with?('.'))
      end

      private def normalized_mime_types(types : Hash(String, String)) : Hash(String, String)
        normalized_types = {} of String => String
        types.each do |extension, type|
          normalized = extension.downcase
          normalized = ".#{normalized}" unless normalized.starts_with?('.')
          raise ArgumentError.new("mime_types extension #{extension.inspect} is not a plain extension") unless EXTENSION.matches?(normalized)
          raise ArgumentError.new("mime_types type #{type.inspect} is not a content type") unless CONTENT_TYPE.matches?(type)
          raise ArgumentError.new("mime_types extension #{extension.inspect} is given twice (as #{normalized.inspect})") if normalized_types.has_key?(normalized)
          normalized_types[normalized] = type
        end
        normalized_types
      end

      private def serve_file(env, path : String, mime_type : String)
        file_path = File.expand_path(path, Dir.current)
        env.response.content_type = mime_type
        env.response.headers["Accept-Ranges"] = "bytes"
        env.response.headers["X-Content-Type-Options"] = "nosniff"
        minsize = 860 # http://webmasters.stackexchange.com/questions/31750/what-is-recommended-minimum-object-size-for-gzip-performance-benefits ??
        request_headers = env.request.headers
        filesize = File.size(file_path)
        File.open(file_path) do |file|
          next serve_range(file, env) if range_request?(env)

          if request_headers.includes_word?("Accept-Encoding", "gzip") && filesize > minsize && zip_file?(file_path)
            gzip_encoding(env, file)
          elsif request_headers.includes_word?("Accept-Encoding", "deflate") && filesize > minsize && zip_file?(file_path)
            deflate_endcoding(env, file)
          else
            env.response.content_length = filesize
            IO.copy(file, env.response)
          end
        end
        return
      end

      private def zip_file?(path)
        ZIPPED_FILE_EXTENSIONS.includes? File.extname(path).downcase
      end

      private def range_request?(env)
        env.request.method == "GET" && env.request.headers.has_key?("Range")
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
