require "logger"

module Azu
  class Configuration
    property port : Int32 = ENV.fetch("PORT", "4000").to_i
    property port_reuse : Bool = ENV.fetch("PORT_REUSE", "false") == "true"
    property host : String = ENV.fetch("HOST", "0.0.0.0")
    property log : Logger
    property env : String = ENV.fetch("AZU_ENV", "development")
    property router : Router = Router.new
    property pipelines : Pipeline = Pipeline.new

    def initialize
      @log = ::Logger.new(writer)
    end

    private def writer
      file = File.new("#{env}.log", "a")
      IO::MultiWriter.new(file, STDOUT)
    end
  end
end
