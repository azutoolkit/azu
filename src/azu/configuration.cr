require "log"
require "openssl"
require "./environment"
require "./router"
require "./templates"
require "./log_format"
require "./cache"
require "./development_tools"

# Conditionally require performance monitor only when needed
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  require "./handler/performance_monitor"
{% end %}

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
    private ERROR_TEMPLATE = "./src/azu/templates"

    Log.setup(:debug, Log::IOBackend.new(formatter: LogFormat))
    property log : Log = Log.for("Azu")

    property port : Int32 = ENV.fetch("PORT", "4000").to_i
    property? port_reuse : Bool = ENV.fetch("PORT_REUSE", "true") == "true"
    property host : String = ENV.fetch("HOST", "0.0.0.0")
    property env : Environment = Environment.parse(ENV.fetch("CRYSTAL_ENV", "development"))

    def self.hot_reload_default
      env = ENV.fetch("CRYSTAL_ENV", "development").downcase
      env == "development" || env == "test" || env == "pipeline"
    end

    property? template_hot_reload : Bool = ENV.fetch("TEMPLATE_HOT_RELOAD", Configuration.hot_reload_default.to_s) == "true"

    property ssl_cert : String = ENV.fetch("SSL_CERT", "")
    property ssl_key : String = ENV.fetch("SSL_KEY", "")
    property ssl_ca : String = ENV.fetch("SSL_CA", "")
    property ssl_mode : String = ENV.fetch("SSL_MODE", "none")

    getter router : Router = Router.new

    getter templates : Templates do
      Templates.new(
        ENV.fetch("TEMPLATES_PATH", Path[TEMPLATES_PATH].expand.to_s).split(","),
        ENV.fetch("ERROR_TEMPLATE", Path[ERROR_TEMPLATE].expand.to_s),
        template_hot_reload?
      )
    end

    getter upload : UploadConfiguration = UploadConfiguration.new

    # i18n configuration
    getter i18n : I18nConfiguration = I18nConfiguration.new

    # Asset pipeline configuration
    getter assets : AssetConfiguration = AssetConfiguration.new

    # Cache configuration and manager
    getter cache : Cache::Manager do
      initialize_cache_with_retry
    end

    # Separate cache configuration object for advanced customization
    getter cache_config : Cache::Configuration do
      Cache::Configuration.new
    end

    # Performance monitoring configuration - defaults to false for truly optional behavior
    property? performance_enabled : Bool = ENV.fetch("PERFORMANCE_MONITORING", "false") == "true"
    property? performance_profiling_enabled : Bool = ENV.fetch("PERFORMANCE_PROFILING", "false") == "true"
    property? performance_memory_monitoring : Bool = ENV.fetch("PERFORMANCE_MEMORY_MONITORING", "false") == "true"

    # Performance monitor instance - truly optional
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      @performance_monitor : Handler::PerformanceMonitor? = nil
    {% end %}

    # Setter for performance monitor to allow sharing instance from handler chain
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      def performance_monitor=(monitor : Handler::PerformanceMonitor?)
        @performance_monitor = monitor
      end
    {% else %}
      def performance_monitor=(monitor)
        # Performance monitoring disabled at compile time
      end
    {% end %}

    # Getter that only creates monitor when explicitly enabled
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      def performance_monitor : Handler::PerformanceMonitor?
        return @performance_monitor if @performance_monitor
        return nil unless performance_enabled?

        @performance_monitor = Handler::PerformanceMonitor.new
      end
    {% else %}
      def performance_monitor : Nil
        nil
      end
    {% end %}

    # Development tools access
    def development_tools
      DevelopmentTools
    end

    def initialize
      # Initialize async logging system
      AsyncLogging.initialize

      # Set performance defaults based on environment (only if not explicitly set)
      if ENV.fetch("PERFORMANCE_PROFILING", "").empty?
        @performance_profiling_enabled = env.development?
      end

      if ENV.fetch("PERFORMANCE_MEMORY_MONITORING", "").empty?
        @performance_memory_monitoring = env.development?
      end

      # Only initialize development tools if performance features are enabled
      if performance_profiling_enabled?
        development_tools.profiler.enabled = true
      end

      if performance_memory_monitoring?
        development_tools.memory_detector.start_monitoring
      end
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
      # Shutdown async logging system
      AsyncLogging.shutdown

      # Only shutdown development tools if they were started
      if performance_memory_monitoring?
        development_tools.memory_detector.stop_monitoring
      end
    end

    # Initialize cache with retry logic and graceful fallback
    private def initialize_cache_with_retry : Cache::Manager
      manager = Cache::Manager.new(cache_config)

      # Connect cache with performance metrics only if available and enabled
      if performance_enabled? && (monitor = performance_monitor)
        manager.metrics = monitor.metrics
      end

      # Test cache connectivity if Redis store is configured
      if cache_config.store == "redis"
        test_redis_connectivity_with_retry(manager)
      end

      manager
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

  # Configuration for file upload handling
  class UploadConfiguration
    property max_file_size : UInt64 = ENV.fetch("UPLOAD_MAX_FILE_SIZE", "10485760").to_u64 # 10MB default
    property temp_dir : String = ENV.fetch("UPLOAD_TEMP_DIR", Dir.tempdir)
    property buffer_size : Int32 = ENV.fetch("UPLOAD_BUFFER_SIZE", "8192").to_i                        # 8KB default
    property cleanup_interval : Time::Span = ENV.fetch("UPLOAD_CLEANUP_INTERVAL", "3600").to_i.seconds # 1 hour
    property max_temp_age : Time::Span = ENV.fetch("UPLOAD_MAX_TEMP_AGE", "86400").to_i.seconds        # 24 hours

    def initialize
      # Ensure temp directory exists and is writable
      Dir.mkdir_p(temp_dir) unless Dir.exists?(temp_dir)

      # Start cleanup background task
      start_cleanup_task
    end

    private def start_cleanup_task
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

    def initialize
      # Initialize i18n system with this configuration
      if load_path.any? { |path| Dir.exists?(path) }
        Helpers::I18n.load_path = load_path
        Helpers::I18n.default_locale = default_locale
        Helpers::I18n.fallback_locale = fallback_locale
        Helpers::I18n.raise_on_missing = raise_on_missing?
        Helpers::I18n.missing_key_format = missing_key_format
        Helpers::I18n.load_translations
      end
    end
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
