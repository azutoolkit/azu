module Azu
  # The `version:` value of a shard.yml text: quotes are stripped and anything after the first colon is kept.
  macro shard_version(yaml)
    {% line = yaml.lines.find { |l| l.starts_with?("version:") } %}
    {% raise "no version: line in shard.yml" unless line %}
    {{ line.gsub(/^version:/, "").strip.gsub(/^["']|["']$/, "") }}
  end
end
