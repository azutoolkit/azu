require "log"
Log.setup_from_env

module Azu
  class Configuration
    property port : Int32 = ENV.fetch("PORT", "4000").to_i
    property port_reuse : Bool = ENV.fetch("PORT_REUSE", "false") == "true"
    property host : String = ENV.fetch("HOST", "0.0.0.0")
    property log : Log = Log.for("Azu")
    property env : String = ENV.fetch("CRYSTAL_ENV", "development")
    property router : Router = Router.new
    property pipelines : Pipeline = Pipeline.new

    def initialize
    end
  end
end
