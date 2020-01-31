module Azu
  module Server
    class_getter config : Configuration = CONFIG
    class_getter log : Logger = CONFIG.log
    class_getter server : HTTP::Server? = nil

    delegate :env, to: Azu

    def self.start
      time = Time.local
      config.pipelines.prepare
      server = HTTP::Server.new(config.pipelines)
      server.bind_tcp config.host, config.port, config.port_reuse

      Signal::INT.trap do
        Signal::INT.reset
        log.info "Shutting down server"
        server.close
      end

      server_info = String.build do |s|
        s << "Environment: #{Azu.env.colorize(:light_blue).underline.bold}"
        s << "Host: #{config.host.colorize(:light_blue).underline.bold}"
        s << "Port: #{config.port.colorize(:light_blue).underline.bold}"
      end

      loop do
        begin
          log.info "Server started in #{time}."
          log.info server_info
          log.info "Startup Time #{Time.local - time}".colorize(:white)
          server.listen
          break
        rescue e : Errno
          if e.errno == Errno::EMFILE
            log.info "Restarting server..."
            sleep 1
          else
            log.error e.message
            break
          end
        end
      end
    end
  end
end
