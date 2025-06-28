require "colorize"
require "log"
require "benchmark"

module Azu
  # Enhanced async logging system with structured pipeline and batch processing
  module AsyncLogging
    # Structured log entry with metadata
    struct LogEntry
      getter timestamp : Time
      getter severity : Log::Severity
      getter message : String
      getter context : Hash(String, String)?
      getter exception : Exception?
      getter source : String
      getter request_id : String?

      def initialize(
        @timestamp,
        @severity,
        @message,
        @context = nil,
        @exception = nil,
        @source = "azu",
        @request_id = nil
      )
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "timestamp", @timestamp.to_rfc3339
          json.field "severity", @severity.to_s.downcase
          json.field "message", @message
          json.field "source", @source
          json.field "request_id", @request_id if @request_id

          if @context
            json.field "context", @context
          end

          if @exception
            json.field "exception" do
              json.object do
                json.field "type", @exception.class.name
                json.field "message", @exception.message
                json.field "backtrace", @exception.backtrace?.try(&.first(10))
              end
            end
          end
        end
      end
    end

    # Batch processor for log entries
    class BatchProcessor
      @@queue = ::Channel(LogEntry).new(1000)
      @@batch_size = 50
      @@flush_interval = 5.seconds
      @@workers = 4
      @@started = false

      def self.start
        return if @@started
        @@started = true

        # Start batch processing workers
        @@workers.times do |i|
          spawn(name: "log-batch-worker-#{i}") do
            worker_loop(i)
          end
        end

        # Start flush timer
        spawn(name: "log-flush-timer") do
          flush_timer_loop
        end
      end

      def self.enqueue(entry : LogEntry)
        @@queue.send(entry)
      rescue ::Channel::ClosedError
        # Fallback to synchronous logging if queue is closed
        Log.for("Azu::AsyncLogging").error { "Log queue closed, falling back to sync logging" }
        process_entry_sync(entry)
      end

      private def self.worker_loop(worker_id : Int32)
        batch = [] of LogEntry
        last_flush = Time.monotonic

        loop do
          select
          when entry = @@queue.receive
            batch << entry

            # Flush if batch is full or enough time has passed
            if batch.size >= @@batch_size || (Time.monotonic - last_flush) >= @@flush_interval
              process_batch(batch, worker_id)
              batch.clear
              last_flush = Time.monotonic
            end
          when timeout(1.second)
            # Periodic flush of partial batches
            if batch.any?
              process_batch(batch, worker_id)
              batch.clear
              last_flush = Time.monotonic
            end
          end
        rescue ex
          Log.for("Azu::AsyncLogging").error(exception: ex) { "Worker #{worker_id} failed" }
          # Process remaining entries synchronously
          batch.each { |entry| process_entry_sync(entry) }
          batch.clear
        end
      end

      private def self.flush_timer_loop
        loop do
          sleep @@flush_interval
          # Force flush of any pending entries
          flush_pending_entries
        rescue ex
          Log.for("Azu::AsyncLogging").error(exception: ex) { "Flush timer failed" }
        end
      end

      private def self.process_batch(batch : Array(LogEntry), worker_id : Int32)
        return if batch.empty?

        # Group by severity for efficient processing
        grouped = batch.group_by(&.severity)

        grouped.each do |severity, entries|
          process_severity_batch(severity, entries, worker_id)
        end

        # Send to external services if configured
        send_to_external_services(batch)
      end

      private def self.process_severity_batch(severity : Log::Severity, entries : Array(LogEntry), worker_id : Int32)
        case severity
        when .error?, .fatal?
          # Process errors with high priority
          entries.each { |entry| process_entry_sync(entry) }
        when .warn?
          # Process warnings with medium priority
          entries.each { |entry| process_entry_sync(entry) }
        else
          # Process info/debug in batches
          batch_message = entries.map(&.message).join("\n")
          log = Log.for("Azu::AsyncLogging")
          case severity
          when .debug? then log.debug { batch_message }
          when .info?  then log.info { batch_message }
          else
            log.info { batch_message }
          end
        end
      end

      private def self.process_entry_sync(entry : LogEntry)
        log = Log.for(entry.source)

        if entry.exception
          case entry.severity
          when .debug? then log.debug(exception: entry.exception) { entry.message }
          when .info?  then log.info(exception: entry.exception) { entry.message }
          when .warn?  then log.warn(exception: entry.exception) { entry.message }
          when .error? then log.error(exception: entry.exception) { entry.message }
          when .fatal? then log.fatal(exception: entry.exception) { entry.message }
          else
            log.info(exception: entry.exception) { entry.message }
          end
        else
          case entry.severity
          when .debug? then log.debug { entry.message }
          when .info?  then log.info { entry.message }
          when .warn?  then log.warn { entry.message }
          when .error? then log.error { entry.message }
          when .fatal? then log.fatal { entry.message }
          else
            log.info { entry.message }
          end
        end
      end

      private def self.send_to_external_services(batch : Array(LogEntry))
        # Send to external logging services (e.g., Sentry, DataDog, etc.)
        return unless CONFIG.env.production?

        spawn(name: "external-log-sender") do
          begin
            # Example: Send to external service
            # ExternalLogService.send_batch(batch)
            Log.for("Azu::AsyncLogging").debug { "Sent #{batch.size} entries to external service" }
          rescue ex
            Log.for("Azu::AsyncLogging").error(exception: ex) { "Failed to send to external service" }
          end
        end
      end

      private def self.flush_pending_entries
        # Force flush any remaining entries in the queue
        pending = [] of LogEntry

        while pending.size < @@batch_size
          select
          when entry = @@queue.receive
            pending << entry
          else
            break
          end
        end

        if pending.any?
          process_batch(pending, -1) # -1 indicates flush worker
        end
      end

      def self.shutdown
        @@started = false
        @@queue.close
      end
    end

    # Background error reporter
    class ErrorReporter
      @@error_queue = ::Channel(Exception).new(100)
      @@started = false

      def self.start
        return if @@started
        @@started = true

        spawn(name: "error-reporter") do
          error_processing_loop
        end
      end

      def self.report_error(exception : Exception)
        @@error_queue.send(exception)
      rescue ::Channel::ClosedError
        # Fallback to immediate reporting
        Log.for("Azu::ErrorReporter").error(exception: exception) { "Error reported synchronously" }
      end

      private def self.error_processing_loop
        loop do
          exception = @@error_queue.receive

          spawn(name: "error-processor") do
            process_error(exception)
          end
        rescue ex
          Log.for("Azu::ErrorReporter").error(exception: ex) { "Error reporter failed" }
        end
      end

      private def self.process_error(exception : Exception)
        # Enhanced error processing
        error_context = {
          "timestamp" => Time.utc.to_rfc3339,
          "type" => exception.class.name,
          "message" => exception.message || "Unknown error",
          "backtrace" => exception.backtrace?.try(&.first(20).join("\n")) || "No backtrace",
          "environment" => CONFIG.env.to_s
        }

        # Log the error
        Log.for("Azu::ErrorReporter").error(exception: exception) {
          "Error processed: #{exception.class.name}"
        }

        # Send to external error reporting service
        send_to_error_service(exception, error_context)
      end

      private def self.send_to_error_service(exception : Exception, context : Hash(String, String))
        return unless CONFIG.env.production?

        spawn(name: "external-error-sender") do
          begin
            # Example: Send to Sentry, Rollbar, etc.
            # ErrorReportingService.report(exception, context)
            Log.for("Azu::ErrorReporter").debug { "Error sent to external service" }
          rescue ex
            Log.for("Azu::ErrorReporter").error(exception: ex) { "Failed to send error to external service" }
          end
        end
      end

      def self.shutdown
        @@started = false
        @@error_queue.close
      end
    end

    # Async logger wrapper
    class AsyncLogger
      getter source : String
      getter request_id : String?

      def initialize(@source : String = "azu", @request_id : String? = nil)
      end

      def with_request_id(request_id : String)
        AsyncLogger.new(@source, request_id)
      end

      def log(severity : Log::Severity, message : String, context : Hash(String, String)? = nil, exception : Exception? = nil)
        entry = LogEntry.new(
          timestamp: Time.utc,
          severity: severity,
          message: message,
          context: context,
          exception: exception,
          source: @source,
          request_id: @request_id
        )

        BatchProcessor.enqueue(entry)
      end

      def info(message : String, context : Hash(String, String)? = nil)
        log(Log::Severity::Info, message, context)
      end

      def debug(message : String, context : Hash(String, String)? = nil)
        log(Log::Severity::Debug, message, context)
      end

      def warn(message : String, context : Hash(String, String)? = nil)
        log(Log::Severity::Warn, message, context)
      end

      def error(message : String, context : Hash(String, String)? = nil, exception : Exception? = nil)
        log(Log::Severity::Error, message, context, exception)
      end

      def fatal(message : String, context : Hash(String, String)? = nil, exception : Exception? = nil)
        log(Log::Severity::Fatal, message, context, exception)
      end
    end

    # Initialize async logging system
    def self.initialize
      BatchProcessor.start
      ErrorReporter.start
    end

    def self.shutdown
      BatchProcessor.shutdown
      ErrorReporter.shutdown
    end
  end

  # :nodoc:
  struct LogFormat < Log::StaticFormatter
    getter orange_red = Colorize::ColorRGB.new(255, 140, 0)

    def run
      string " AZU ".colorize.fore(:white).back(:blue)
      string "  "
      string @entry.timestamp.to_s("%a %m/%d/%Y %I:%M:%S")
      string " ⤑  "
      string severity_colored(@entry.severity)
      string " ⤑  "
      string Log.progname.capitalize.colorize.bold
      string " ⤑  "
      message
      exception
    end

    def exception(*, before = '\n', after = nil)
      if ex = @entry.exception
        @io << before

        # Always show the basic exception info
        @io << "   ⤑  Exception: ".colorize(:light_red)
        @io << ex.class.name.colorize(:red).bold
        @io << "\n"

        @io << "   ⤑  Message: ".colorize(:light_gray)
        @io << (ex.message || "No message").colorize(:cyan)
        @io << "\n"

        # Show custom exception fields if they exist
        if ex.responds_to? :title
          @io << "   ⤑  Title: ".colorize(:light_gray)
          @io << ex.title.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :status
          @io << "   ⤑  Status: ".colorize(:light_gray)
          @io << ex.status_code.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :link
          @io << "   ⤑  Link: ".colorize(:light_gray)
          @io << ex.link.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :detail
          @io << "   ⤑  Detail: ".colorize(:light_gray)
          @io << ex.detail.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :source
          @io << "   ⤑  Source: ".colorize(:light_gray)
          @io << ex.source.colorize(:cyan)
          @io << "\n"
        end

        # Show backtrace
        if backtrace = ex.backtrace?
          @io << "   ⤑  Backtrace: ".colorize(:light_gray)
          @io << "\n"
          backtrace.first(10).each_with_index do |frame, index|
            @io << "     #{index + 1}. ".colorize(:dark_gray)
            @io << frame.colorize(:cyan)
            @io << "\n"
          end
        else
        @io << "   ⤑  Backtrace: ".colorize(:light_gray)
          @io << "No backtrace available".colorize(:dark_gray)
          @io << "\n"
        end

        @io << after if after
      end
    end

    private def severity_colored(severity)
      output = " #{severity} ".colorize.fore(:white)
      case severity
      when ::Log::Severity::Info                          then output.back(:green).bold
      when ::Log::Severity::Debug                         then output.back(:blue).bold
      when ::Log::Severity::Warn                          then output.back(orange_red).bold
      when ::Log::Severity::Error, ::Log::Severity::Fatal then output.back(:red).bold
      else
        output.back(:black).bold
      end
    end
  end
end
