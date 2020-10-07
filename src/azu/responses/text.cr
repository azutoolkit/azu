module Azu
  module Response
    module Text
      include Response

      abstract def text

      def to_s
        text
      end
    end
  end
end
