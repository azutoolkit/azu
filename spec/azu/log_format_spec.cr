require "../spec_helper"

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
