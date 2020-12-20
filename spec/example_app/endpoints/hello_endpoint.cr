module ExampleApp
  # Endpoints
  struct HelloWorld
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      header "Custom", "Fake custom header"
      HtmlPage.new "World!"
    end
  end

  struct HtmlEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      request.validate!
      status 200
      header "Custom", "Fake custom header"
      HtmlPage.new request.name
    end

    private def request
      ExampleReq.new params
    end
  end

  struct LoadTest
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      request.validate!
      HtmlPage.new request.name
    end

    private def request
      ExampleReq.new params
    end
  end
end
