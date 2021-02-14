module ExampleApp
  struct TextResponse
    include Response::Text

    def text
      "Hello World!"
    end
  end
end
