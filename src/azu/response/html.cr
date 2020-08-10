require "html_builder"

module Azu
  module Html
    include Response
    private getter build = HTML::Builder.new
    forward_missing_to build

    abstract def html

    def to_s
      html
    end
  end
end
