require "xml"

module Azu
  module Response
    module Xml
      include Response

      abstract def xml

      def to_s
        xml
      end
    end
  end
end
