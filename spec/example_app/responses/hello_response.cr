module ExampleApp
  struct HelloView
    include Response::Html

    def initialize(@name : String)
      header "Custom", "Fake custom header"
    end

    def html
      h1 { text "Hello #{@name}!" }
    end
  end

  struct JsonData
    include Response::Json

    def json
      {data: "Hello World"}.to_json
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
