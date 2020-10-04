require "json"

module Azu
  module Json
    include Response

    abstract def json

    def to_s
      json
    end
  end
end
