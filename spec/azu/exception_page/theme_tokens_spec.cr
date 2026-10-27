require "../../spec_helper"

# The exception page, the production error page, the dev dashboard and the playground (and the welcome page azu_cli
# generates from the same tokens) read as one product: their colour tokens must not drift apart.
private SHARED = %w(bg glow-a glow-b glass text muted faint accent on-accent focus good warn bad border hover)

private def tokens(css : String) : Hash(String, String)
  css.scan(/--([a-z0-9-]+):\s*([^;]+);/).to_h { |match| {match[1], normalize(match[2])} }
end

# `0.10` and `0.1` are the same alpha.
private def normalize(value : String) : String
  value.strip.gsub(/(\.\d*?)0+\b/) { |_, match| match[1] == "." ? "" : match[1] }
end

# The light and the dark value of every token, from `light-dark()` declarations.
private def light_dark(css : String) : {Hash(String, String), Hash(String, String)}
  pairs = tokens(css).compact_map do |name, value|
    value.match(/\Alight-dark\((.+),\s*([^,]+)\)\z/).try { |match| {name, {match[1].strip, match[2].strip}} }
  end
  {pairs.to_h { |name, values| {name, values[0]} }, pairs.to_h { |name, values| {name, values[1]} }}
end

# The light tokens of the first `:root` block and the dark ones of the `prefers-color-scheme: dark` block.
private def scheme_blocks(css : String) : {Hash(String, String), Hash(String, String)}
  dark_at = css.index("prefers-color-scheme: dark").not_nil!
  {tokens(css[0, dark_at]), tokens(css[dark_at..].split(/\n\s*\}\s*\n/).first)}
end

private def shared(values : Hash(String, String)) : Hash(String, String)
  values.select { |name, _| SHARED.includes?(name) }
end

describe "Azu's page themes" do
  dashboard_light, dashboard_dark = light_dark(File.read("src/azu/ui/dashboard.css"))

  it "share the dashboard's tokens on the production error page" do
    light, dark = scheme_blocks(File.read("src/azu/templates/error.html"))

    shared(light).should eq shared(dashboard_light).select { |name, _| light.has_key?(name) }
    shared(dark).should eq shared(dashboard_dark).select { |name, _| dark.has_key?(name) }
    shared(light).size.should be >= 12
  end

  it "share the dashboard's tokens on the playground" do
    light, dark = scheme_blocks(File.read("playground/public/assets/app.css"))
    common = SHARED.select { |name| light.has_key?(name) && dashboard_light.has_key?(name) && name != "border-strong" }

    common.to_h { |name| {name, light[name]} }.should eq common.to_h { |name| {name, dashboard_light[name]} }
    common.to_h { |name| {name, dark[name]} }.should eq common.to_h { |name| {name, dashboard_dark[name]} }
  end
end
