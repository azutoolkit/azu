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
        template_hot_reload
      )
    end

    getter upload : UploadConfiguration = UploadConfiguration.new

    # Cache configuration and manager
    getter cache : Cache::Manager do
      manager = Cache::Manager.new(cache_config)
      # Connect cache with performance metrics only if available and enabled
      if performance_enabled && (monitor = performance_monitor)
        manager.metrics = monitor.metrics
      end
      manager
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
        return nil unless performance_enabled

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
      if performance_profiling_enabled
        development_tools.profiler.enabled = true
      end

      if performance_memory_monitoring
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
      if performance_memory_monitoring
        development_tools.memory_detector.stop_monitoring
      end
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
end
