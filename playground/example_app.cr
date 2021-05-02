require "../src/azu"

module ExampleApp
  include Azu
  configure do
    templates.path = "playground/templates"
  end
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

ExampleApp.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
