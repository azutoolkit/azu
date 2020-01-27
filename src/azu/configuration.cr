module Azu
  class Configuration
    property port : Int32 = 4000
    property port_reuse : Bool = true
    property host : String = "0.0.0.0"
    property log : Logger = Logger.new(STDOUT)
    property env : String = "development"
    property router : Router = Router.new
    property pipelines : Pipeline = Pipeline.new
  end
end
