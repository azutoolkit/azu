require "log"

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
  #   c.template.path = "./templates"
  #   c.template.error_path = "./error_template"
  # end
  # ```
  class Configuration
    private TEMPLATES_PATH = "../../templates"
    private ERROR_TEMPLATE = "./src/azu/templates"

    Log.setup(:debug, Log::IOBackend.new(formatter: LogFormat))

    property port : Int32 = ENV.fetch("PORT", "4000").to_i
    property port_reuse : Bool = ENV.fetch("PORT_REUSE", "true") == "true"
    property host : String = ENV.fetch("HOST", "0.0.0.0")
    property log : Log = Log.for("Azu")
    property env : Environment = Environment.parse(ENV.fetch("CRYSTAL_ENV", "development"))

    getter router : Router = Router.new
    getter templates : Templates = Templates.new(
      ENV.fetch("TEMPLATES_PATH", Path[TEMPLATES_PATH].expand.to_s),
      ENV.fetch("ERROR_TEMPLATE", Path[ERROR_TEMPLATE].expand.to_s)
    )
  end
end
