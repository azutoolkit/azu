module ExampleApp
  struct HelloView
    include Azu::Html

    def initialize(@name : String)
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
      doctype
      body do
        a(href: "http://crystal-lang.org") do
          text "#{@name} is awesome"
        end
      end
    end
  end
end
