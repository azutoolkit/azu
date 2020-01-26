require "http"
require "radix"
require "./azu/**"

module Azu
  VERSION  = "0.1.0"
  ROUTES   = Radix::Tree(Tuple(Symbol, Endpoint.class)).new
  PIPELINE = Pipeline.new
end
