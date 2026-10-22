require "./markup"

module Azu
  # A static piece of HTML written with the `Azu::Markup` DSL: define `content`, call `render`.
  #
  # ```
  # class Greeting
  #   include Azu::Component
  #
  #   def initialize(@name : String)
  #   end
  #
  #   def content
  #     h1 "Hello #{@name}"
  #   end
  # end
  #
  # Greeting.new("Azu").render # => "<h1>Hello Azu</h1>"
  # ```
  #
  # Components that react to user input and update the page over a WebSocket are
  # `Azu::Spark::Component`s.
  module Component
    include Markup

    # Describes the HTML; override in the including class.
    def content
    end

    def render : String
      @view = IO::Memory.new
      content
      to_s
    end
  end
end
