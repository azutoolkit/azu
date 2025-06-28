require "../src/azu"

module ExampleApp
  include Azu
  configure do
    templates.path = "playground/templates"
    # Enable hot reload for development and specs/pipeline testing
    # This allows template changes to be picked up automatically during testing
    template_hot_reload = true
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
