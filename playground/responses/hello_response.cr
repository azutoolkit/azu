module ExampleApp
  struct HelloView
    include Response::Html

    def initialize(@name : String)
    end

    def html
      h1 { text "Hello #{@name}!" }
    end
  end

  struct HtmlPage
    include Response::Html

    def initialize(@name : String)
    end

    def html
      render "example.html", {name: @name}
    end
  end
end
