module ExampleApp
  struct HtmlEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    get "/html/:name"
    get "/html"

    def call : HtmlPage
      status 200
      content_type "text/html"
      header "custom", "Fake custom header"
      HtmlPage.new example_req.name
    end
  end
end
