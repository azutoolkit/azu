module ExampleApp
  # The greeting page, kept as a small response of its own: it renders `example.html`
  # inside the shared layout.
  struct HtmlPage
    include Response

    def initialize(@name : String, @context : HTTP::Server::Context? = nil, @served_by : String = "HtmlEndpoint", @error : String? = nil)
    end

    def render
      Page.new("example.html", @context, "hello", name: @name, served_by: @served_by, error: @error).render
    end
  end
end
