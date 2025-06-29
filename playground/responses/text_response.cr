module ExampleApp
  struct TextResponse
    include Azu::Response

    def initialize(@data : String = "Hello World!")
    end

    def render
      @data
    end
  end
end
