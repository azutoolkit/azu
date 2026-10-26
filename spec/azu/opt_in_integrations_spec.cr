require "../spec_helper"
require "file_utils"

# Azu core must stay usable without the cql shard: anything that needs it lives in
# an opt-in directory that src/azu.cr does not glob. `dev` (the dashboard and performance tooling) and
# `testing` (the in-process test client) are opt-in too, but need no extra shard.
describe "opt-in database integrations" do
  opt_in_dirs = %w(cql dev testing)
  # Run at build time by `Azu::Templates.compile`, never required by the app
  build_time_dirs = %w(template_compiler)

  it "does not glob the whole azu directory" do
    File.read("src/azu.cr").should_not contain(%(require "./azu/**"))
  end

  it "loads every core directory explicitly (a new directory must be added to src/azu.cr)" do
    core = Dir.children("src/azu").select { |name| File.directory?("src/azu/#{name}") && !opt_in_dirs.includes?(name) && !build_time_dirs.includes?(name) }
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

# Which dev tooling a program that requires `requires` ends up with, found by asking the compiler.
private def loaded_dev_constants(requires : String, flags : Array(String) = [] of String) : Array(String)
  dir = File.tempname("azu-dev")
  Dir.mkdir_p(dir)
  program = File.join(dir, "main.cr")
  File.write(program, <<-CR)
    #{requires}
    {% begin %}
      {% names = [] of String %}
      {% for name in %w(PerformanceMetrics PerformanceReporter DevelopmentTools Testing) %}
        {% names << name if Azu.has_constant?(name) %}
      {% end %}
      {% for name in %w(DevDashboard PerformanceMonitor) %}
        {% names << "Handler::\#{name.id}" if Azu::Handler.has_constant?(name) %}
      {% end %}
      {% names << "Configuration#development_tools" if Azu::Configuration.has_method?("development_tools") %}
      {% puts "LOADED:" + names.join(",") %}
    {% end %}
    CR
  search_path = [File.expand_path("../../src", __DIR__), File.expand_path("../../lib", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", program, *flags], env: {"CRYSTAL_PATH" => search_path, "PERFORMANCE_MONITORING" => nil}, output: output, error: error)
  fail "child program failed:\n#{error}" unless status.success?

  line = output.to_s.lines.find(&.starts_with?("LOADED:")) || fail("no report in:\n#{output}")
  line.lchop("LOADED:").split(',', remove_empty: true)
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "opt-in test client" do
  it "is loaded by `require \"azu/testing\"` and not by `require \"azu\"`" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    loaded_dev_constants(%(require "azu")).should be_empty
    loaded_dev_constants(%(require "azu/testing")).should eq ["Testing"]
  end
end

describe "opt-in development tooling" do
  everything = %w(PerformanceMetrics PerformanceReporter DevelopmentTools Handler::DevDashboard Handler::PerformanceMonitor Configuration#development_tools)

  it "is not loaded by `require \"azu\"`" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    loaded_dev_constants(%(require "azu")).should be_empty
  end

  it "is loaded by `require \"azu/dev\"`" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    loaded_dev_constants(%(require "azu"\nrequire "azu/dev")).sort.should eq everything.sort
  end

  it "is loaded by `require \"azu\"` when built with -Dperformance_monitoring" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    loaded_dev_constants(%(require "azu"), ["-Dperformance_monitoring"]).sort.should eq everything.sort
  end
end
