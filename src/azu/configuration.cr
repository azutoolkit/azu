require "log"
Log.setup_from_env

module Azu
  class Configuration
    TEMPLATES_PATH = "../../templates"
    ERROR_TEMPLATE = "./src/azu/templates"

    property port : Int32 = ENV.fetch("PORT", "4000").to_i
    property port_reuse : Bool = ENV.fetch("PORT_REUSE", "false") == "true"
    property host : String = ENV.fetch("HOST", "0.0.0.0")
    property log : Log = Log.for("Azu")
    property env : Environment = Environment.parse(ENV.fetch("CRYSTAL_ENV", "development"))
    property router : Router = Router.new
    property pipelines : Pipeline = Pipeline.new
    getter templates : Templates = Templates.new ENV.fetch("TEMPLATES_PATH", Path[TEMPLATES_PATH].expand.to_s), ENV.fetch("ERROR_TEMPLATE", Path[ERROR_TEMPLATE].expand.to_s)
  end
end
