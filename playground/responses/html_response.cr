module ExampleApp
  struct HtmlPage
    include Response
    include Templates::Renderable

    def initialize(@name : String)
    end

    def render
      view "example.html", {name: @name}
    end
  end
end
