module ExampleApp
  struct HtmlEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    get "/html/:name", accept: "text/html", content_type: "text/html"

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end
