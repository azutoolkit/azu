require "../../../spec_helper"

private def render_asset(source : String, variables = {} of String => String) : String
  crinja = Crinja.new
  Azu::Helpers::Registry.apply_to(crinja)
  crinja.from_string(source).render(variables)
end

describe "Asset Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::AssetHelpers.register
  end

  describe "the URL an asset helper prints" do
    it "keeps an http(s) URL and a site-absolute path, and prefixes a protocol-relative one like a relative path" do
      render_asset(%({{ image_tag("https://cdn.example/a.png") }})).should contain %(src="https://cdn.example/a.png")
      render_asset(%({{ image_tag("/img/a.png") }})).should contain %(src="/img/a.png")
      render_asset(%({{ image_tag("a.png") }})).should contain %(src="/assets/a.png")
      render_asset(%({{ image_tag("//evil.example/a.png") }})).should contain %(src="/assets/evil.example/a.png")
      render_asset(%({{ javascript_tag("//evil.example/x.js") }})).should contain %(src="/assets/evil.example/x.js")
      render_asset(%({{ stylesheet_tag("//evil.example/x.css") }})).should contain %(href="/assets/evil.example/x.css")
      # browsers read `/\host` as `//host` and skip a control character after the slash
      render_asset(%({{ image_tag(src) }}), {"src" => "/\\evil.example/a.png"}).should contain %(src="/assets/evil.example/a.png")
      render_asset(%({{ image_tag(src) }}), {"src" => "/\t/evil.example/a.png"}).should contain %(src="/assets/\t/evil.example/a.png")

      # a root prefix too: the URL stays on this host
      Azu::Helpers::Builtin::AssetHelpers.asset_prefix = "/"
      begin
        render_asset(%({{ image_tag("//evil.example/a.png") }})).should contain %(src="/evil.example/a.png")
        render_asset(%({{ image_tag("a.png") }})).should contain %(src="/a.png")
      ensure
        Azu::Helpers::Builtin::AssetHelpers.asset_prefix = "/assets"
      end
    end
  end

  describe "inline_svg function" do
    it "reads only files below public/<asset prefix>" do
      created = !Dir.exists?("public/assets/icons")
      Dir.mkdir_p("public/assets/icons")
      File.write("public/assets/icons/ok.svg", %(<svg viewBox="0 0 1 1"></svg>))
      secret = File.tempfile("secret", ".svg") { |file| file.print %(<svg>secret</svg>) }
      begin
        render_asset(%({{ inline_svg("icons/ok.svg", class="i") }})).should eq %(<svg class="i" viewBox="0 0 1 1"></svg>)
        render_asset(%({{ inline_svg("#{secret.path}") }})).should contain "SVG not found"
        render_asset(%({{ inline_svg("../../#{secret.path.lstrip('/')}") }})).should contain "SVG not found"
        render_asset(%({{ inline_svg("icons/../../../etc/hostname") }})).should contain "SVG not found"
        render_asset(%({{ inline_svg("") }})).should contain "SVG not found"

        File.symlink(secret.path, "public/assets/icons/link.svg")
        render_asset(%({{ inline_svg("icons/link.svg") }})).should contain "SVG not found" # a link that leads out

        Azu::Helpers::Builtin::AssetHelpers.asset_prefix = "/assets/" # a trailing slash changes nothing
        render_asset(%({{ inline_svg("icons/ok.svg") }})).should eq %(<svg viewBox="0 0 1 1"></svg>)
      ensure
        Azu::Helpers::Builtin::AssetHelpers.asset_prefix = "/assets"
        secret.delete
        File.delete("public/assets/icons/link.svg") if File.symlink?("public/assets/icons/link.svg")
        File.delete("public/assets/icons/ok.svg")
        Dir.delete("public/assets/icons") if created && Dir.empty?("public/assets/icons")
      end
    end
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

    it "defaults a font to anonymous when crossorigin names an undefined variable" do
      result = render_asset("{{ preload_tag('/f.woff2', as='font', crossorigin=missing) }}")

      result.should contain %(crossorigin="anonymous")
    end
  end
end
