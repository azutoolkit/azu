module ExampleApp
  struct EmptyRequest
    include Request
  end

  # Endpoints
  class HelloWorld
    include Azu::Endpoint(EmptyRequest, HtmlPage)

    def call : HtmlPage
      header "Custom", "Fake custom header"
      HtmlPage.new "World!"
    end
  end

  class HtmlEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      example_req.validate!
      header "Custom", "Fake custom header"
      HtmlPage.new example_req.name
    end
  end

  class LoadTestEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end
