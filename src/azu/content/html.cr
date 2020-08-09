require "html_builder"

module Azu
  module Html
    macro included
      getter build = HTML::Builder.new
      forward_missing_to build
    end

    abstract def html
  end
end
