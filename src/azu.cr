require "http"
require "log"
require "radix"
require "json"
require "xml"
require "colorize"
require "schema"
require "crinja"

require "./azu/**"

module Azu
  VERSION = "0.1.1"
  CONFIG  = Configuration.new

  macro included
    def self.configure
      with CONFIG yield CONFIG
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
      CONFIG.env
    end

    def self.config
      CONFIG
    end

    def self.start
      time = Time.monotonic
      config.pipelines.prepare
      server = HTTP::Server.new(config.pipelines)
      server.bind_tcp config.host, config.port, config.port_reuse

      Signal::INT.trap do
        Signal::INT.reset
        log.info { "\nShutting down server" }
        server.close
      end

      server_info = String.build do |s|
        s << "Server started at #{Time.local.to_s("%a %m/%d/%Y %I:%M:%S")}.".colorize(:white).underline
        s << "\n   ⤑  Environment: ".colorize(:white)
        s << env.colorize(:light_blue)
        s << "\n   ⤑  Host: ".colorize(:white)
        s << config.host.colorize(:light_blue)
        s << "\n   ⤑  Port: ".colorize(:white)
        s << config.port.colorize(:light_blue)
        s << "\n   ⤑  Startup Time: ".colorize(:white)
        s << (Time.monotonic - time).total_milliseconds
        s << " millis".colorize(:white)
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
