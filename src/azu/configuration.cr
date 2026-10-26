require "./error_format"
require "log"
require "http/server/handler"
require "openssl"
require "./environment"
require "./router"
require "./templates"
require "./log_format"
require "./cache"
require "./instrumentation"
require "./spark/configuration"

module Azu
  # Holds all the configuration properties for your Azu Application
  #
  # Azu expects configurations to be loaded from environment variables
  # for local development it is recommended to use `.env` files to store
  # your development configuration properties.
  #
  #
  # ```
  # Azu.configure do |c|
  #   c.port = 4000
  #   c.host = localhost
  #   c.port_reuse = true
  #   c.log = Log.for("My Awesome App")
  #   c.env = Environment::Development
  #   c.template_hot_reload = true
  #   c.template.path = "./templates"
  #   c.template.error_path = "./error_template"
  #   c.upload.max_file_size = 10.megabytes
  #   c.upload.temp_dir = "/tmp/uploads"
  #   c.cache.enabled = true
  #   c.cache.store = "memory"
  #   c.cache.max_size = 1000
  # end
  # ```
  class Configuration
    private TEMPLATES_PATH = "../../templates"
    # Where Azu's own error pages live in the source tree. Resolved at compile time, so it does not depend on the
    # working directory; it may not exist at run time (a deployed binary), where `Templates::BUILTIN` serves them.
    private ERROR_TEMPLATE = {{ "#{__DIR__}/templates" }}

    property log : Log = Log.for("Azu")

    property port : Int32 = Env.int("PORT", 4000)

    # How long a stopping server waits for requests in flight before giving up on them.
    property shutdown_timeout : Time::Span = Math.max(ENV["SHUTDOWN_TIMEOUT"]?.try(&.to_i?) || 30, 0).seconds
    property? port_reuse : Bool = ENV.fetch("PORT_REUSE", "true") == "true"
    # The address the server binds. Unless `HOST` or `host=` set one, it is `127.0.0.1` in development, so a
    # forgotten `CRYSTAL_ENV` (unset means development) does not put the debug pages on every interface, and
    # `0.0.0.0` in every other environment. An explicit value is always kept, `0.0.0.0` included.
    @host : String? = Env.fetch?("HOST")

    def host : String
      @host || (env.development? ? LOOPBACK_HOST : ANY_HOST)
    end

    def host=(host : String?) : String?
      @host = host.presence
    end

    # The host as `HOST` or `host=` set it, nil while the environment's default applies (`host` answers that default).
    # What a spec saves and restores, so restoring `host` itself would not pin the default.
    def configured_host : String?
      @host
    end

    # True when `host` was not set by `HOST` or `host=` and is the development default.
    def host_from_default? : Bool
      @host.nil? && env.development?
    end

    # True when the address is only reachable from the machine itself.
    def loopback_host? : Bool
      address = host
      address == "localhost" || address == "::1" || address == "[::1]" || address.starts_with?("127.")
    end

    # Files a container runtime leaves in the container: Docker's and Podman's.
    CONTAINER_MARKERS = ["/.dockerenv", "/run/.containerenv"]

    def self.container_detected?(markers : Array(String) = CONTAINER_MARKERS) : Bool
      markers.any? { |marker| File.exists?(marker) } || !ENV["KUBERNETES_SERVICE_HOST"]?.presence.nil?
    end

    # Whether the process looks containerised (Docker, Podman or Kubernetes). Detected when the configuration is built;
    # a spec or a container runtime Azu cannot recognise sets it.
    property? container : Bool = Configuration.container_detected?

    LOOPBACK_HOST = "127.0.0.1"
    ANY_HOST      = "0.0.0.0"

    @env : Environment = Environment.parse(Env.environment)
    @env_from_default : Bool = Env.fetch?("CRYSTAL_ENV").nil?

    getter env : Environment

    def env=(@env : Environment) : Environment
      @env_from_default = false
      @env
    end

    # True while the environment is the one Azu falls back to (development) because `CRYSTAL_ENV` is not set and
    # the app did not choose one.
    def env_from_default? : Bool
      @env_from_default
    end

    # Logs, when the environment is the default, that it is, and where the server will listen. `App#start` calls it.
    def announce_default_environment : Nil
      return unless env_from_default?
      log.info { "CRYSTAL_ENV not set, running in #{env.to_s.downcase}, listening on #{host}" }
    end

    # Warns about the two ways the bind address surprises: a loopback address inside a container (nothing outside it
    # can connect: the usual cause is the development default, fixed by `HOST=0.0.0.0`), and the development pages
    # served on every interface because `CRYSTAL_ENV` was never set. `App#start` calls it.
    def warn_about_bind_host : Nil
      if loopback_host? && container?
        origin = host_from_default? ? "the development default" : "the configured host"
        log.warn { "listening on #{host} (#{origin}) inside a container: connections from outside the container are refused. Set HOST=0.0.0.0 to accept them" }
      elsif env_from_default? && !loopback_host?
        log.warn { "CRYSTAL_ENV is not set, so this is a development server, and it listens on #{host}: the development dashboard and debug pages are served on every interface. Set CRYSTAL_ENV (production, staging, ...) or bind 127.0.0.1" }
      end
    end

    def self.hot_reload_default
      env = Env.environment
      env == "development" || env == "test" || env == "pipeline"
    end

    @template_hot_reload : Bool = ENV.fetch("TEMPLATE_HOT_RELOAD", Configuration.hot_reload_default.to_s) == "true"
    # Template names not preloaded at boot (see `Templates#preload_ignore`); `TEMPLATE_PRELOAD_IGNORE` takes a comma separated
    # list (`TEMPLATE_COMPILE_IGNORE`, its name in 0.5.113 to 0.5.132, now deprecated, is read when it is not set).
    @template_preload_ignore : Array(String) = ENV.fetch("TEMPLATE_PRELOAD_IGNORE") { ENV.fetch("TEMPLATE_COMPILE_IGNORE", "") }
      .split(',').map(&.strip).reject(&.empty?)

    def template_hot_reload? : Bool
      @template_hot_reload
    end

    # Also applies to the templates of this configuration when they were built already.
    def template_hot_reload=(enabled : Bool)
      @template_hot_reload = enabled
      @templates.try(&.hot_reload = enabled)
    end

    # Escape `{{ }}` output of `.jinja`, `.j2` and string templates like `.html` (default). `TEMPLATE_AUTOESCAPE=false`
    # turns it off; any other value keeps it on. `| safe` marks a value as markup without turning it off.
    @template_autoescape_env : String? = ENV["TEMPLATE_AUTOESCAPE"]?
    @template_autoescape_set = false
    @template_autoescape : Bool = ENV.fetch("TEMPLATE_AUTOESCAPE", "true") != "false"

    # Warns that autoescape is off (every `{{ }}` of a `.jinja` page is then raw HTML), or that `TEMPLATE_AUTOESCAPE`
    # holds a value that is neither "true" nor "false" and so left it on. `App#start` calls it.
    def warn_about_template_autoescape : Nil
      value = @template_autoescape_set ? nil : @template_autoescape_env # the setter overrides the variable
      if !template_autoescape?
        log.warn { "template_autoescape is off: {{ }} output of .jinja and .j2 templates is not escaped, so every unescaped user value is an XSS hole. Turn it on again, or escape with `| e`" }
      elsif value && !value.empty? && value != "true"
        log.warn { "TEMPLATE_AUTOESCAPE=#{value.inspect} is not recognised (only \"true\" and \"false\" are); autoescape stays on" }
      end
    end

    def template_autoescape? : Bool
      @template_autoescape
    end

    # Also applies to the templates of this configuration when they were built already.
    def template_autoescape=(enabled : Bool)
      @template_autoescape = enabled
      @template_autoescape_set = true
      @templates.try(&.autoescape = enabled)
    end

    getter template_preload_ignore : Array(String)

    def template_preload_ignore=(patterns : Array(String))
      @template_preload_ignore = patterns
      @templates.try(&.preload_ignore = patterns)
    end

    @[Deprecated("Use `template_preload_ignore`.")]
    def template_compile_ignore : Array(String)
      template_preload_ignore
    end

    @[Deprecated("Use `template_preload_ignore=`.")]
    def template_compile_ignore=(patterns : Array(String))
      self.template_preload_ignore = patterns
    end

    property ssl_cert : String = ENV.fetch("SSL_CERT", "")
    property ssl_key : String = ENV.fetch("SSL_KEY", "")
    property ssl_ca : String = ENV.fetch("SSL_CA", "")
    property ssl_mode : String = ENV.fetch("SSL_MODE", "none")

    @router = Router.new

    # The router of this configuration. The global `Azu::CONFIG` first takes the routes the endpoint
    # macros declared since it was last read (see `DeclaredEndpoints`).
    def router : Router
      DeclaredEndpoints.apply_to(@router) if same?(CONFIG)
      @router
    end

    # How template helpers and the session CSRF token store reach the session library (see `SessionAdapter`).
    property session_adapter : SessionAdapter? = nil

    # The shape of validation failures: an RFC 7807 problem body (labelled `application/problem+json` only for a client that names it in `Accept`), or the pre-0.6 body.
    property error_format : ErrorFormat = ErrorFormat::Problem

    # The query parameter that picks the format of a `Response::Negotiable` (`?format=json`), or nil
    # to turn it off. A value that is not a format name (html, json, xml, text, txt) is ignored, so an
    # endpoint can have its own `format` field; rename the parameter if it also takes those values.
    property format_parameter : String? = "format"

    # The middleware pipeline handed to `Azu.start`, in execution order. Recorded
    # for introspection only (the development dashboard draws it).
    property handlers : Array(HTTP::Handler) = [] of HTTP::Handler

    getter templates : Templates do
      Templates.new(
        ENV.fetch("TEMPLATES_PATH", Path[TEMPLATES_PATH].expand.to_s).split(","),
        ENV.fetch("ERROR_TEMPLATE", Path[ERROR_TEMPLATE].expand.to_s),
        template_hot_reload?,
        template_preload_ignore,
        template_autoescape?
      )
    end

    getter upload : UploadConfiguration = UploadConfiguration.new

    # WebSocket security and keep-alive settings shared by `Azu::Channel`s
    getter websocket : WebSocketConfiguration = WebSocketConfiguration.new

    # Spark live views (see `Azu::Spark`)
    getter spark : Spark::Configuration = Spark::Configuration.new

    # i18n configuration
    getter i18n : I18nConfiguration = I18nConfiguration.new

    # Asset pipeline configuration
    getter assets : AssetConfiguration = AssetConfiguration.new

    # Database integration settings (see `azu/cql`)
    getter database : DatabaseConfiguration = DatabaseConfiguration.new

    # Whether the dashboard may show bound values and unredacted database errors: `database.show_params` in development only.
    def show_database_params? : Bool
      database.show_params? && env.development?
    end

    # Cache configuration and manager
    getter cache : Cache::Manager do
      initialize_cache_with_retry
    end

    # Separate cache configuration object for advanced customization
    getter cache_config : Cache::Configuration do
      Cache::Configuration.new
    end

    # Starts what needs a running app: the upload temp directory and its cleanup task, plus whatever
    # `Instrumentation.on_prepare` hooks add (`azu/dev` starts the profiler and memory monitor).
    # `Azu.start` calls this; building a configuration, and so requiring azu, starts nothing.
    def prepare : Nil
      templates.prepare # App#prepare calls it first, before logging starts; this second call is a cheap no-op
      cache_config.validate!
      Instrumentation.prepare(self)
      upload.prepare
    end

    def tls
      OpenSSL::SSL::Context::Server.from_hash({
        "key"         => ssl_key,
        "cert"        => ssl_cert,
        "ca"          => ssl_ca,
        "verify_mode" => ssl_mode,
      })
    end

    def tls?
      !ssl_cert.empty? && !ssl_key.empty?
    end

    def finalize
      Instrumentation.finalize(self)
    end

    # Initialize cache with retry logic and graceful fallback
    private def initialize_cache_with_retry : Cache::Manager
      manager = Cache::Manager.new(cache_config)

      # Test cache connectivity if Redis store is configured
      if cache_config.store == "redis"
        test_redis_connectivity_with_retry(manager)
      end

      manager
    rescue ex : ArgumentError
      # A misconfigured cache (no Redis URL, unknown store) must fail the boot, not quietly turn caching off. Only
      # an unreachable Redis, or another runtime failure, falls back below.
      raise ex
    rescue ex
      log.error(exception: ex) { "Cache initialization failed, falling back to NullStore" }
      # Fall back to NullStore if initialization fails
      fallback_config = Cache::Configuration.new
      fallback_config.enabled = false
      Cache::Manager.new(fallback_config)
    end

    # Test Redis connectivity with retry logic
    private def test_redis_connectivity_with_retry(manager : Cache::Manager)
      retries = cache_config.cache_connection_retries
      delay = cache_config.cache_connection_retry_delay

      retries.times do |attempt|
        begin
          if manager.ping == "PONG"
            log.info { "Redis cache connection successful" }
            return
          end
        rescue ex
          log.warn(exception: ex) { "Redis connection attempt #{attempt + 1}/#{retries} failed" }
        end

        if attempt < retries - 1
          sleep(delay.seconds)
          delay *= 2 # Exponential backoff
        end
      end

      raise "Redis connection failed after #{retries} attempts"
    end
  end

  # Settings for database instrumentation and the dev dashboard's database tab.
  #
  # The connection itself is CQL's: set the URL and pool with `Azu::CQL.configure { |c| c.db = ... }`.
  class DatabaseConfiguration
    # Deprecated fallback for `Azu::CQL.schema` when `CQL.config.db` was never set (defaults to
    # `DATABASE_URL`). Prefer `Azu::CQL.configure { |c| c.db = ENV["DATABASE_URL"] }`.
    property uri : String? = Env.fetch?("DATABASE_URL")
    # Open the connection on the first query instead of when the schema is created, so the app
    # (and tasks that only load it) boots without a database. `Azu::CQL.verify!` fails fast.
    property? lazy_connect : Bool = ENV.fetch("AZU_DB_LAZY", "true") == "true"
    # Which connection layer `Azu::CQL.schema` uses for `postgres://` and `postgresql://` URLs: "engine" (CQL's native
    # PostgreSQL `AsyncEngine` pool, the default) or "db" (crystal-db's pool, with whichever driver is registered,
    # e.g. the `pg` shard). `cockroachdb://` URLs use "db" unless this is "engine". From `AZU_CQL_DRIVER`; the
    # `driver:` argument of `Azu::CQL.schema` wins.
    property driver : String? = Env.fetch?("AZU_CQL_DRIVER")
    # Record queries/transactions into `Azu::QueryStore`.
    property? instrument : Bool = ENV.fetch("AZU_DB_INSTRUMENT", "true") == "true"
    # Show the bound values of each statement in the dashboard and keep database error text as the server wrote it.
    # Off by default, and only honoured in development: values often hold personal data or secrets. Turning it on
    # also turns on `CQL::Telemetry.capture_params` (CQL leaves values out of its events otherwise).
    property? show_params : Bool = ENV.fetch("AZU_DB_SHOW_PARAMS", "false") == "true"
    # Same query shape this many times in one request raises an N+1 alert.
    property n_plus_one_threshold : Int32 = ENV.fetch("AZU_DB_N_PLUS_ONE_THRESHOLD", "3").to_i
    # Queries slower than this (ms) are flagged as slow.
    property slow_query_ms : Float64 = ENV.fetch("AZU_DB_SLOW_QUERY_MS", "50").to_f
    # Enables the dashboard SQL playground (still limited to Development + loopback clients).
    property? playground : Bool = ENV.fetch("AZU_DB_PLAYGROUND", "true") == "true"
  end

  # Configuration for file upload handling
  class UploadConfiguration
    property max_file_size : UInt64 = ENV.fetch("UPLOAD_MAX_FILE_SIZE", "10485760").to_u64 # 10MB default
    property temp_dir : String = ENV.fetch("UPLOAD_TEMP_DIR", Dir.tempdir)
    property buffer_size : Int32 = ENV.fetch("UPLOAD_BUFFER_SIZE", "8192").to_i                        # 8KB default
    property cleanup_interval : Time::Span = ENV.fetch("UPLOAD_CLEANUP_INTERVAL", "3600").to_i.seconds # 1 hour
    property max_temp_age : Time::Span = ENV.fetch("UPLOAD_MAX_TEMP_AGE", "86400").to_i.seconds        # 24 hours

    @cleanup_started = false
    @cleanup_lock = Mutex.new

    # Creates the temp directory and starts the cleanup task, once. `Azu.start` calls this, and so
    # does the first upload for apps that never call `start`; nothing happens when the configuration
    # is built, so requiring azu leaves no directory or fiber behind.
    def prepare : Nil
      Dir.mkdir_p(temp_dir) unless Dir.exists?(temp_dir)
      start_cleanup_task
    end

    private def start_cleanup_task
      @cleanup_lock.synchronize do
        return if @cleanup_started
        @cleanup_started = true
      end
      spawn(name: "upload-cleanup") do
        loop do
          sleep cleanup_interval
          cleanup_old_files
        end
      rescue ex
        Log.for("Azu::UploadConfiguration").error(exception: ex) { "Upload cleanup task failed" }
      end
    end

    private def cleanup_old_files
      return unless Dir.exists?(temp_dir)

      Dir.glob(Path[temp_dir, "azu_upload_*"].to_s).each do |file_path|
        next unless ::File.exists?(file_path)

        file_age = Time.utc - ::File.info(file_path).modification_time
        if file_age > max_temp_age
          begin
            ::File.delete(file_path)
            Log.for("Azu::UploadConfiguration").debug { "Cleaned up old upload file: #{file_path}" }
          rescue ex
            Log.for("Azu::UploadConfiguration").warn(exception: ex) { "Failed to cleanup upload file: #{file_path}" }
          end
        end
      end
    rescue ex
      Log.for("Azu::UploadConfiguration").error(exception: ex) { "Upload cleanup failed" }
    end
  end

  # Configuration for WebSocket channels
  #
  # ```
  # Azu.configure do |c|
  #   c.websocket.allowed_origins = ["https://app.example.com"]
  #   c.websocket.max_message_size = 64 * 1024
  #   c.websocket.ping_interval = 20.seconds
  # end
  # ```
  class WebSocketConfiguration
    # Origins accepted besides the request's own origin; "*" accepts any origin
    property allowed_origins : Array(String) = ENV.fetch("WEBSOCKET_ALLOWED_ORIGINS", "").split(',').map(&.strip).reject(&.empty?)

    # Largest accepted message in bytes; bigger messages close the connection
    property max_message_size : Int32 = ENV.fetch("WEBSOCKET_MAX_MESSAGE_SIZE", "1048576").to_i

    # Interval between server pings, nil disables them
    property ping_interval : Time::Span? = begin
      seconds = ENV.fetch("WEBSOCKET_PING_INTERVAL", "30").to_i
      seconds > 0 ? seconds.seconds : nil
    end

    # Turns Nagle's algorithm off on upgraded sockets (`TCP_NODELAY`). On by default: a Spark event is
    # answered by two small writes, and with Nagle on the second waits for the peer's delayed ACK
    # (about 40 ms per round trip on a Linux peer). Set `WEBSOCKET_TCP_NODELAY=false` to keep the
    # operating system's default. Plain TCP sockets are set at the upgrade; a TLS listener started by
    # `Azu.start` is built on `Azu::NoDelayTCPServer`, so every connection it accepts is set.
    property? tcp_nodelay : Bool = WebSocketConfiguration.flag("WEBSOCKET_TCP_NODELAY", true)

    # Reads a boolean variable: true, 1, on, yes / false, 0, off, no (any case). Anything else keeps
    # *default* and logs one warning naming the variable.
    def self.flag(name : String, default : Bool) : Bool
      value = ENV[name]?.try(&.strip.downcase)
      return default if value.nil? || value.empty?
      case value
      when "true", "1", "on", "yes"  then true
      when "false", "0", "off", "no" then false
      else
        Log.for("Azu").warn { "#{name} is not a boolean (use true or false); keeping #{default}" }
        default
      end
    end
  end

  # Configuration for internationalization (i18n)
  #
  # ```
  # Azu.configure do |c|
  #   c.i18n.load_path = ["locales", "config/locales"]
  #   c.i18n.default_locale = "en"
  #   c.i18n.available_locales = ["en", "es", "fr"]
  #   c.i18n.fallback_locale = "en"
  # end
  # ```
  class I18nConfiguration
    # Directories to load translation files from
    property load_path : Array(String) = ENV.fetch("I18N_LOAD_PATH", "locales").split(",")

    # Default locale for the application
    property default_locale : String = ENV.fetch("I18N_DEFAULT_LOCALE", "en")

    # Available locales (auto-detected if empty)
    property available_locales : Array(String) = ENV.fetch("I18N_AVAILABLE_LOCALES", "").split(",").reject(&.empty?)

    # Fallback locale when translation is missing
    property fallback_locale : String? = begin
      value = ENV.fetch("I18N_FALLBACK_LOCALE", "")
      value.empty? ? nil : value
    end

    # Whether to raise on missing translations (useful for development)
    property? raise_on_missing : Bool = ENV.fetch("I18N_RAISE_ON_MISSING", "false") == "true"

    # Format for missing translation keys
    property missing_key_format : String = ENV.fetch("I18N_MISSING_KEY_FORMAT", "[missing: %{key}]")

    # Building the settings changes nothing outside this object. `App#server` calls `apply`, which hands
    # the settings that differ from the built-in defaults (set in code or through `I18N_*`) to the
    # process-wide `Helpers::I18n`. Settings left at their defaults are not passed on, so an explicit
    # `Helpers::I18n.configure` is never overwritten by defaults.
    def apply : Nil
      Helpers::I18n.load_path = load_path if load_path != DEFAULT_LOAD_PATH && load_path.any? { |path| Dir.exists?(path) }
      Helpers::I18n.default_locale = default_locale if default_locale != DEFAULT_LOCALE
      Helpers::I18n.fallback_locale = fallback_locale if fallback_locale
      Helpers::I18n.raise_on_missing = raise_on_missing? if raise_on_missing?
      Helpers::I18n.missing_key_format = missing_key_format if missing_key_format != DEFAULT_MISSING_KEY_FORMAT
    end

    DEFAULT_LOAD_PATH          = ["locales"]
    DEFAULT_LOCALE             = "en"
    DEFAULT_MISSING_KEY_FORMAT = "[missing: %{key}]"
  end

  # Configuration for asset pipeline
  #
  # ```
  # Azu.configure do |c|
  #   c.assets.prefix = "/assets"
  #   c.assets.path = "public/assets"
  #   c.assets.fingerprint = true
  #   c.assets.manifest_path = "public/assets/manifest.json"
  # end
  # ```
  class AssetConfiguration
    # URL prefix for asset paths
    property prefix : String = ENV.fetch("ASSETS_PREFIX", "/assets")

    # File system path to assets directory
    property path : String = ENV.fetch("ASSETS_PATH", "public/assets")

    # Whether to append content hash fingerprints to asset URLs
    property? fingerprint : Bool = ENV.fetch("ASSETS_FINGERPRINT", "true") == "true"

    # Path to asset manifest file (for fingerprinted assets)
    property manifest_path : String = ENV.fetch("ASSETS_MANIFEST_PATH", "public/assets/manifest.json")

    # Cache-Control header max-age for assets (in seconds)
    property cache_max_age : Int32 = ENV.fetch("ASSETS_CACHE_MAX_AGE", "31536000").to_i # 1 year

    # Whether to include integrity hashes (SRI)
    property? integrity : Bool = ENV.fetch("ASSETS_INTEGRITY", "false") == "true"

    # Loaded manifest data (cached)
    @manifest : Hash(String, String)? = nil
    @manifest_mutex : Mutex = Mutex.new
    @manifest_mtime : Time? = nil

    def initialize
    end

    # Get the fingerprinted path for an asset
    def fingerprinted_path(asset : String) : String
      return "#{prefix}/#{asset}" unless fingerprint?

      manifest_data = load_manifest
      if fingerprinted = manifest_data[asset]?
        "#{prefix}/#{fingerprinted}"
      else
        "#{prefix}/#{asset}"
      end
    end

    # Load or reload the asset manifest
    def load_manifest : Hash(String, String)
      @manifest_mutex.synchronize do
        if (cached = @manifest) && !manifest_changed?
          return cached
        end

        if File.exists?(manifest_path)
          begin
            content = File.read(manifest_path)
            @manifest = Hash(String, String).from_json(content)
            @manifest_mtime = File.info(manifest_path).modification_time
          rescue ex
            Log.for("Azu::AssetConfiguration").warn(exception: ex) { "Failed to load asset manifest" }
            @manifest = {} of String => String
          end
        else
          @manifest = {} of String => String
        end

        @manifest || {} of String => String
      end
    end

    private def manifest_changed? : Bool
      mtime = @manifest_mtime
      return true unless mtime
      return false unless File.exists?(manifest_path)

      File.info(manifest_path).modification_time > mtime
    rescue
      false
    end
  end
end
