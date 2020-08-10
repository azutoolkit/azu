require "http"
require "logger"
require "radix"
require "json"
require "xml"
require "colorize"
require "schema"

require "./azu/**"

module Azu
  VERSION     = "0.1.0"
  CONFIG      = Configuration.new
  ENVIRONMENT = Environment.parse ENV.fetch("CRYSTAL_ENV", "development")

  macro included
    def self.configure
      with CONFIG yield
    end

    def self.pipelines
      with CONFIG.pipelines yield
    end

    def self.router
      with CONFIG.router yield
    end

    def self.log
      CONFIG.log
    end

    def self.env
      ENVIRONMENT
    end

    def self.config
      CONFIG
    end

    def self.start
      time = Time.local
      config.pipelines.prepare
      server = HTTP::Server.new(config.pipelines)
      server.bind_tcp config.host, config.port, config.port_reuse

      Signal::INT.trap do
        Signal::INT.reset
        log.info { "Shutting down server" }
        server.close
      end

      server_info = String.build do |s|
        s << "Server started in #{time}. "
        s << "Environment: #{env.colorize(:light_blue).underline.bold} "
        s << "Host: #{config.host.colorize(:light_blue).underline.bold} "
        s << "Port: #{config.port.colorize(:light_blue).underline.bold} "
        s << "Startup Time #{(Time.local - time).total_milliseconds} millis".colorize(:white)
      end

      loop do
        begin
          log.info { server_info }
          server.listen
          break
        rescue e
          if e == Errno
            log.info(exception: e) { "Restarting server..." }
            sleep 1
          else
            log.error(exception: e) { "Server failed to start!" }
            break
          end
        end
      end
    end

  end
end
