require "../spec_helper"
require "file_utils"

# Every entry written to `Log` while the block runs, from any fiber.
private def capture_log_entries(&) : Array(Log::Entry)
  backend = Log::MemoryBackend.new
  Log.builder.bind("*", :trace, backend)
  begin
    yield
  ensure
    Log.builder.unbind("*", :trace, backend)
  end
  backend.entries
end

# Compiles and runs `source` as a program of its own, so its `at_exit` handlers run.
private def run_exiting_program(source : String) : {String, String, Process::Status}
  dir = File.tempname("azu-async-logging")
  Dir.mkdir_p(dir)
  program = File.join(dir, "main.cr")
  File.write(program, source)
  search_path = [File.expand_path("../../src", __DIR__), File.expand_path("../../lib", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("crystal", ["run", "--no-color", program], env: {"CRYSTAL_PATH" => search_path}, output: output, error: error)
  {output.to_s, error.to_s, status}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Azu::LogFormat do
  describe "LogFormat" do
    it "creates log format instance with required parameters" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.should be_a(Log::StaticFormatter)
    end

    it "has orange_red color property" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.orange_red.should be_a(Colorize::ColorRGB)
    end

    it "formats log entry with timestamp and severity" do
      entry = Log::Entry.new("test", Log::Severity::Info, "Test message", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.run

      output = io.to_s
      output.should contain("AZU")
      output.should contain("Test message")
    end

    it "handles different severity levels" do
      severities = [Log::Severity::Debug, Log::Severity::Info, Log::Severity::Warn, Log::Severity::Error, Log::Severity::Fatal]

      severities.each do |severity|
        entry = Log::Entry.new("test", severity, "Test message", Log::Metadata.new, nil)
        io = IO::Memory.new
        formatter = Azu::LogFormat.new(entry, io)
        formatter.run

        output = io.to_s
        output.should contain("AZU")
        output.should contain("Test message")
      end
    end

    it "formats exceptions when present" do
      exception = Exception.new("Test exception")
      entry = Log::Entry.new("test", Log::Severity::Error, "Error occurred", Log::Metadata.new, exception)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.run

      output = io.to_s
      output.should contain("AZU")
      output.should contain("Error occurred")
      output.should contain("Backtrace")
    end
  end

  describe "AsyncLogging" do
    describe "lifecycle" do
      it "stays running when a Configuration is finalized" do
        Azu::AsyncLogging.initialize
        Azu::Configuration.new.finalize

        Azu::AsyncLogging.running?.should be_true
      end
    end

    describe ".shutdown" do
      it "writes every queued entry and reported error before it returns" do
        Azu::AsyncLogging.initialize
        logger = Azu::AsyncLogging::AsyncLogger.new("spec.shutdown")

        entries = capture_log_entries do
          120.times { |i| logger.info("queued info #{i}") }
          3.times { |i| logger.warn("queued warn #{i}") }
          Azu::AsyncLogging::ErrorReporter.report_error(Exception.new("queued error"))

          Azu::AsyncLogging.shutdown
        end

        written = entries.map(&.message).join("\n")
        120.times { |i| written.should match(/^queued info #{i}$/m) }
        3.times { |i| written.should contain("queued warn #{i}") }
        entries.count(&.exception.try(&.message.==("queued error"))).should eq 1
        Azu::AsyncLogging.running?.should be_false
      ensure
        Azu::AsyncLogging.initialize
      end

      it "is safe to call again, writes later entries synchronously and starts again with initialize" do
        Azu::AsyncLogging.shutdown
        Azu::AsyncLogging.shutdown

        entries = capture_log_entries do
          Azu::AsyncLogging::AsyncLogger.new("spec.shutdown").info("after shutdown")
        end
        entries.map(&.message).should eq ["after shutdown"]

        Azu::AsyncLogging.initialize
        Azu::AsyncLogging.running?.should be_true
        entries = capture_log_entries do
          Azu::AsyncLogging::AsyncLogger.new("spec.shutdown").info("after restart")
          Azu::AsyncLogging.shutdown
        end
        entries.map(&.message).should eq ["after restart"]
      ensure
        Azu::AsyncLogging.initialize
      end

      it "is called by Azu.shutdown" do
        Azu::AsyncLogging.initialize

        entries = capture_log_entries do
          Azu::AsyncLogging::AsyncLogger.new("spec.shutdown").info("before Azu.shutdown")
          Azu.shutdown
        end

        entries.map(&.message).should contain("before Azu.shutdown")
      ensure
        Azu::AsyncLogging.initialize
      end

      it "runs at exit, before Log closes its async dispatcher" do
        next pending!("crystal is not installed") unless Process.find_executable("crystal")

        output, error, status = run_exiting_program(<<-CR)
          require "azu"
          Log.setup(:info, Log::IOBackend.new(STDOUT))
          logger = Azu::AsyncLogging::AsyncLogger.new("child")
          5.times { |i| logger.info("entry \#{i}") }
          Azu::AsyncLogging::ErrorReporter.report_error(Exception.new("reported"))
          CR

        status.success?.should be_true
        error.should_not contain("Unhandled exception")
        5.times { |i| output.should contain("entry #{i}") }
        output.should contain("Error processed: Exception")
      end
    end

    describe "LogEntry" do
      it "creates log entry with required fields" do
        entry = Azu::AsyncLogging::LogEntry.new(
          Time.utc,
          Log::Severity::Info,
          "Test message"
        )

        entry.timestamp.should be_a(Time)
        entry.severity.should eq(Log::Severity::Info)
        entry.message.should eq("Test message")
        entry.source.should eq("azu")
      end

      it "creates log entry with optional fields" do
        context = {"user_id" => "123", "action" => "login"}
        exception = Exception.new("Test error")

        entry = Azu::AsyncLogging::LogEntry.new(
          Time.utc,
          Log::Severity::Error,
          "Error occurred",
          context,
          exception,
          "auth",
          "req_123"
        )

        entry.context.should eq(context)
        entry.exception.should eq(exception)
        entry.source.should eq("auth")
        entry.request_id.should eq("req_123")
      end
    end

    describe "AsyncLogger" do
      it "creates async logger with default source" do
        logger = Azu::AsyncLogging::AsyncLogger.new
        logger.source.should eq("azu")
        logger.request_id.should be_nil
      end

      it "creates async logger with custom source" do
        logger = Azu::AsyncLogging::AsyncLogger.new("api")
        logger.source.should eq("api")
      end

      it "creates logger with request ID" do
        logger = Azu::AsyncLogging::AsyncLogger.new("api", "req_123")
        logger.request_id.should eq("req_123")
      end

      it "creates logger with request ID using with_request_id" do
        logger = Azu::AsyncLogging::AsyncLogger.new("api")
        logger_with_id = logger.with_request_id("req_456")

        logger_with_id.source.should eq("api")
        logger_with_id.request_id.should eq("req_456")
      end
    end
  end
end
