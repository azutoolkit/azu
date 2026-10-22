require "../spec_helper"
require "file_utils"

# Requiring a library must not start work. These specs run a child program that does nothing but
# `require "azu"` and report what is running, so state set up by other specs cannot hide a leak.

private PROGRAM = <<-CR
  require "azu"
  Fiber.yield
  names = [] of String
  Fiber.each { |fiber| names << fiber.name.to_s }
  puts names.sort.join(",")
  puts Dir.exists?(ENV["UPLOAD_TEMP_DIR"])
  puts Log.for("").level
CR

private def report : Array(String)
  source = File.expand_path("../../src", __DIR__)
  dir = File.tempname("azu-require")
  Dir.mkdir_p(dir)
  program = File.join(dir, "main.cr")
  File.write(program, PROGRAM)
  output = IO::Memory.new
  search_path = "#{source}:lib:#{`crystal env CRYSTAL_PATH`.strip}"
  env = {"UPLOAD_TEMP_DIR" => File.join(dir, "uploads"), "CRYSTAL_PATH" => search_path}
  status = Process.run("crystal", ["run", "--no-color", program], env: env, output: output, error: output)
  fail "child program failed:\n#{output}" unless status.success?
  output.to_s.lines
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "requiring azu" do
  it "starts no background fibers, creates no directory and leaves the log level alone" do
    next pending!("crystal is not installed") unless Process.find_executable("crystal")

    names, upload_dir, log_level = report

    names.split(",").select(&.matches?(/\A(upload-cleanup|log-|error-reporter)/)).should be_empty
    upload_dir.should eq "false"
    log_level.should eq "Info"
  end
end
