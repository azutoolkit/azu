module Azu
  class Views::Error < View
    def initialize(errors : Array(Error))
    end

    def html
    end

    def json
      @errors.to_json
    end

    def text
    end
  end
end