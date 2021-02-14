module ExampleApp
  struct HtmlPage
    include Response::Html

    def initialize(@name : String)
    end

    def html
      render "example.html", {name: @name}
    end
  end
end
