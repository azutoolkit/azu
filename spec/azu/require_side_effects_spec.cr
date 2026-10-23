require "../spec_helper"
require "file_utils"

# Requiring a library must not start work. These specs run child programs, so state set up by other
# specs cannot hide a leak: one requires only the standard library (the baseline), the other
# requires azu, and the two must look the same from the outside. The main fiber is not reported: the
# runtime lists it only sometimes, and it is not something requiring a library can start.

private REPORT = <<-CR
  Fiber.yield
  names = [] of String
  Fiber.each { |fiber| names << fiber.name.to_s unless fiber.name == "main" }
  puts "REPORT:" + {fibers: names.sort, upload_dir: Dir.exists?(ENV["UPLOAD_TEMP_DIR"]), log_level: Log.for("").level.to_s}.to_json
CR

private record Observed, fibers : Array(String), upload_dir : Bool, log_level : String do
  include JSON::Serializable
end

private def observe(requires : String) : Observed
  dir = File.tempname("azu-require")
  Dir.mkdir_p(dir)
  program = File.join(dir, "main.cr")
  File.write(program, "#{requires}\nrequire \"json\"\n#{REPORT}")
  search_path = [File.expand_path("../../src", __DIR__), File.expand_path("../../lib", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
  # Development is the environment that turns the profiler and memory monitor on by default.
  env = {
    "CRYSTAL_PATH"    => search_path,
    "CRYSTAL_ENV"     => "development",
    "LOG_LEVEL"       => nil,
    "UPLOAD_TEMP_DIR" => File.join(dir, "uploads"),
  }
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("crystal", ["run", "--no-color", program], env: env, output: output, error: error)
  fail "child program failed:\n#{error}" unless status.success?

  line = output.to_s.lines.find(&.starts_with?("REPORT:")) || fail("no report in:\n#{output}")
  Observed.from_json(line.lchop("REPORT:"))
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "requiring azu" do
  it "starts nothing beyond the standard library, creates no directory and leaves the log level alone" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    baseline = observe(%(require "http"\nrequire "log"))
    azu = observe(%(require "azu"))

    azu.fibers.should eq baseline.fibers
    azu.upload_dir.should be_false
    azu.log_level.should eq baseline.log_level
  end
end

describe Azu do
  describe ".prepare" do
    it "leaves the application's own Log setup alone" do
      begin
        Log.setup(:warn, Log::MemoryBackend.new)

        Azu.prepare

        Log.for("").level.should eq Log::Severity::Warn
      ensure
        Log.setup(:info)
      end
    end
  end
end
