require "json"

module Azu
  module Response
    module Json
      include Response

      abstract def json

      def to_s
        json
      end
    end
  end
end
