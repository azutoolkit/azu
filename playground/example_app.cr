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
  Azu::Handler::RequestId.new, # Enhanced request ID tracking
  Azu::Handler::Rescuer.new,   # Enhanced error handling
  Azu::Handler::Logger.new,
]
