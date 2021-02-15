module ExampleApp
  struct TextResponse
    include Response

    def render
      "Hello World!"
    end
  end
end
