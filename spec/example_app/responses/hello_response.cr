module ExampleApp
  struct HelloView
    include Azu::Html

    def initialize(@name : String)
      header "Custom", "Fake custom header"
    end

    def html
      h1 { text "Hello #{@name}!" }
    end
  end

  struct JsonData
    include Azu::Json

    def json
      {data: "Hello World"}.to_json
    end
  end

  struct HtmlPage
    include Azu::Html

    def initialize(@name : String)
    end

    def html
      render "example.html", {name: @name}
    end
  end
end
