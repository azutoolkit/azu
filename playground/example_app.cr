require "../src/azu"

module ExampleApp
  include Azu
  configure do
    templates.path = "playground/templates"
    pipelines = [
      Azu::Handler::Rescuer.new,
      Azu::Handler::Logger.new,
    ]
  end
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

ExampleApp.start
