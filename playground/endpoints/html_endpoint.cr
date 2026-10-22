module ExampleApp
  struct HtmlEndpoint
    include Azu::Endpoint(ExampleReq, HtmlPage)

    get "/html/:name"
    get "/html"

    def call : HtmlPage
      content_type "text/html"
      header "custom", "Fake custom header"

      name = example_req.name
      return HtmlPage.new(name, context) unless name.empty?

      # No name yet: show the form. A submitted-but-blank form explains what is missing.
      submitted = params.query.has_key?("name")
      status 422 if submitted
      HtmlPage.new("", context, error: submitted ? "Please tell us your name so we can greet you." : nil)
    end
  end
end
