require "../spec_helper"

# Azu core must stay usable without the cql shard: anything that needs it lives in
# an opt-in directory that src/azu.cr does not glob.
describe "opt-in database integrations" do
  opt_in_dirs = %w(cql database model migrations)

  it "does not glob the whole azu directory" do
    File.read("src/azu.cr").should_not contain(%(require "./azu/**"))
  end

  it "loads every core directory explicitly (a new directory must be added to src/azu.cr)" do
    core = Dir.children("src/azu").select { |name| File.directory?("src/azu/#{name}") && !opt_in_dirs.includes?(name) }
    source = File.read("src/azu.cr")
    missing = core.reject { |name| source.includes?(%(require "./azu/#{name}/**")) }
    missing.should be_empty
  end

  it "keeps `require \"cql\"` inside opt-in directories" do
    offenders = Dir.glob("src/azu/**/*.cr").select do |path|
      next false if opt_in_dirs.any? { |dir| path.starts_with?("src/azu/#{dir}/") }
      File.read(path).each_line.any? { |line| line.strip.starts_with?(%(require "cql")) }
    end
    offenders.should be_empty
  end

  it "does not require opt-in directories from core files" do
    core = Dir.glob("src/azu/**/*.cr").reject { |path| opt_in_dirs.any? { |dir| path.starts_with?("src/azu/#{dir}/") } }
    offenders = core.select do |path|
      File.read(path).each_line.any? do |line|
        stripped = line.strip
        stripped.starts_with?("require") && opt_in_dirs.any? { |dir| stripped.includes?("/#{dir}/") || stripped.includes?(%("azu/#{dir}")) }
      end
    end
    offenders.should be_empty
  end
end
