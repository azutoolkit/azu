module ExampleApp
  struct EmptyRequest
    include Request
  end

  # Endpoints
  struct HelloWorld
    include Endpoint(EmptyRequest, HtmlPage)

    get "/hello", accept: "text/html", content_type: "text/html"

    def call : HtmlPage
      header "Custom", "Fake custom header"
      HtmlPage.new "World!"
    end
  end

  struct HtmlEndpoint
    include Endpoint(ExampleReq, HtmlPage)

    get "/hello/:name", accept: "text/html", content_type: "text/html"

    def call : HtmlPage
      example_req.validate!
      header "Custom", "Fake custom header"
      HtmlPage.new example_req.name
    end
  end

  struct LoadTestEndpoint
    include Endpoint(ExampleReq, HtmlPage)

    get "/load/:name", accept: "text/html", content_type: "text/html"

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end
