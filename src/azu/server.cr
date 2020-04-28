module Azu
  module Server
    class_getter config : Configuration = CONFIG
    class_getter log : ::Log = Azu.log.for(self)
    class_getter server : HTTP::Server? = nil

    delegate :env, to: Azu

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
        s << "Environment: #{Azu.env.colorize(:light_blue).underline.bold} "
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
