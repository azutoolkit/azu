require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

module PathFilterSpec
  struct Page
    include Azu::Response

    def render : String
      "page"
    end
  end

  class NotesEndpoint
    include Azu::Endpoint(TestRequest, Page)

    get "/path-filter-notes/:id"

    def call : Page
      Page.new
    end
  end
end

# The `<resource>_path` template filter an endpoint declares belongs to every app's templates, not only the global one.
describe "the endpoint path filter in templates" do
  it "is available to the templates of an app built as a value" do
    app = Azu::App.new
    with_temp_dir({"note.jinja" => "{{ '' | path_filter_spec_notes_path(id=7) }}"}) do |dir|
      app.config.templates.path = dir
      app.config.templates.load("note.jinja").render.should eq "/path-filter-notes/7"
    end
  end

  it "is still available after the helper registry is reset" do
    Azu::Helpers::Registry.reset!
    app = Azu::App.new
    with_temp_dir({"note.jinja" => "{{ '' | path_filter_spec_notes_path(id=8) }}"}) do |dir|
      app.config.templates.path = dir
      app.config.templates.load("note.jinja").render.should eq "/path-filter-notes/8"
    end
  end
end
