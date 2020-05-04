module Azu
  abstract class View
    class NotImplemented < Error
    end

    def html
      raise NotImplemented.new
    end

    def json
      raise NotImplemented.new
    end

    def text
      raise NotImplemented.new
    end

    def xml
      raise NotImplemented.new
    end
  end
end
