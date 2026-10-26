require "../../../spec_helper"

private def render_asset(source : String) : String
  crinja = Crinja.new
  Azu::Helpers::Registry.apply_to(crinja)
  crinja.from_string(source).render
end

describe "Asset Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::AssetHelpers.register
  end

  describe "preload_tag function" do
    it "outputs a crossorigin string as given" do
      result = render_asset("{{ preload_tag('/data.json', as='fetch', crossorigin='use-credentials') }}")

      result.should contain %(crossorigin="use-credentials")
    end

    it "escapes a crossorigin string" do
      result = render_asset(%({{ preload_tag('/data.json', as='fetch', crossorigin='a"b') }}))

      result.should contain %(crossorigin="a&quot;b")
    end

    it "outputs anonymous for crossorigin=true" do
      result = render_asset("{{ preload_tag('/data.json', as='fetch', crossorigin=true) }}")

      result.should contain %(crossorigin="anonymous")
    end

    it "omits crossorigin for crossorigin=false, even for a font" do
      result = render_asset("{{ preload_tag('/f.woff2', as='font', crossorigin=false) }}")

      result.should_not contain "crossorigin"
    end

    it "omits crossorigin when absent" do
      result = render_asset("{{ preload_tag('/app.css', as='style') }}")

      result.should_not contain "crossorigin"
    end

    it "defaults a font to anonymous when absent" do
      result = render_asset("{{ preload_tag('/f.woff2', as='font') }}")

      result.should contain %(crossorigin="anonymous")
    end
  end
end
