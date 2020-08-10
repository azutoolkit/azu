require "xml"

module Azu
  module Xml
    abstract def xml

    def to_s
      xml
    end
  end
end
