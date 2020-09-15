module ExampleApp
  # Endpoints
  struct HelloWorld
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      header "Custom", "Fake custom header"
      HtmlPage.new "World!"
    end
  end

  struct JsonEndpoint
    include Azu::Endpoint(ExampleReq, JsonData)

    def call : JsonData
      JsonData.new
    end
  end

  struct HtmlEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      request.verify!
      status 200
      header "Custom", "Fake custom header"
      HtmlPage.new request.name
    end
  end

  struct LoadTest
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      request.verify!
      HtmlPage.new request.name
    end
  end
end
