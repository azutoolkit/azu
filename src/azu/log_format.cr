require "colorize"
require "log"
require "benchmark"
require "wait_group"

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
        @request_id = nil,
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
      @@stop = ::Channel(Nil).new
      @@done = WaitGroup.new
      @@batch_size = 50
      @@flush_interval = 5.seconds
      @@workers = 4
      @@started = false
      @@start_lock = Mutex.new

      # Starts the workers and the flush timer. After `shutdown` it opens a new queue, so an app
      # started again logs asynchronously again.
      def self.start
        @@start_lock.synchronize do
          return if @@started
          @@started = true
          reopen if @@queue.closed?
          @@done = WaitGroup.new(@@workers + 1)
          spawn_fibers(@@queue, @@stop, @@done)
        end
        AsyncLogging.shutdown_at_exit
      end

      private def self.reopen : Nil
        @@queue = ::Channel(LogEntry).new(1000)
        @@stop = ::Channel(Nil).new
      end

      private def self.spawn_fibers(queue : ::Channel(LogEntry), stop : ::Channel(Nil), done : WaitGroup) : Nil
        @@workers.times do |i|
          spawn(name: "log-batch-worker-#{i}") do
            worker_loop(queue, i)
          ensure
            done.done
          end
        end

        spawn(name: "log-flush-timer") do
          flush_timer_loop(queue, stop)
        ensure
          done.done
        end
      end

      def self.enqueue(entry : LogEntry)
        start unless @@queue.closed?
        @@queue.send(entry)
      rescue ::Channel::ClosedError
        # The pipeline was shut down: write the entry now
        process_entry_sync(entry)
      end

      # Closes the queue and waits until the workers have written every entry it held. Entries sent
      # afterwards are written synchronously. Safe to call again, and when the pipeline never started.
      def self.shutdown : Nil
        done = @@start_lock.synchronize do
          @@started = false
          @@queue.close
          @@stop.close
          @@done
        end
        done.wait
      end

      private def self.worker_loop(queue : ::Channel(LogEntry), worker_id : Int32)
        batch = [] of LogEntry
        last_flush = Time.instant

        loop do
          select
          when entry = queue.receive
            batch << entry

            # Flush if batch is full or enough time has passed
            if batch.size >= @@batch_size || (Time.instant - last_flush) >= @@flush_interval
              process_batch(batch, worker_id)
              batch.clear
              last_flush = Time.instant
            end
          when timeout(1.second)
            # Periodic flush of partial batches
            if !batch.empty?
              process_batch(batch, worker_id)
              batch.clear
              last_flush = Time.instant
            end
          end
        rescue ::Channel::ClosedError
          # The queue is closed and empty: write what this worker still holds
          process_batch(batch, worker_id)
          break
        rescue ex
          report_failure(ex) { "Worker #{worker_id} failed" }
          # Process remaining entries synchronously
          batch.each { |log_entry| process_entry_sync(log_entry) }
          batch.clear
        end
      end

      private def self.flush_timer_loop(queue : ::Channel(LogEntry), stop : ::Channel(Nil))
        loop do
          select
          when stop.receive?
            break
          when timeout(@@flush_interval)
            # Force flush of any pending entries
            flush_pending_entries(queue)
          end
        rescue ::Channel::ClosedError
          break
        rescue ex
          report_failure(ex) { "Flush timer failed" }
        end
      end

      private def self.report_failure(ex : Exception, &) : Nil
        message = yield
        Log.for("Azu::AsyncLogging").error(exception: ex) { message }
      rescue ::Channel::ClosedError
        STDERR.puts "#{message}: #{ex.message}"
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
          log_batched(severity, entries)
        end
      end

      # Info/debug entries are written as one message
      private def self.log_batched(severity : Log::Severity, entries : Array(LogEntry))
        batch_message = entries.map(&.message).join("\n")
        log = Log.for("Azu::AsyncLogging")
        if severity.debug?
          log.debug { batch_message }
        else
          log.info { batch_message }
        end
      rescue ::Channel::ClosedError
        entries.each { |entry| write_to_stderr(entry) }
      end

      private def self.process_entry_sync(entry : LogEntry)
        log = Log.for(entry.source)
        log_entry_by_severity(log, entry)
      rescue ::Channel::ClosedError
        write_to_stderr(entry)
      end

      # `Log`'s async dispatcher is closed (its `at_exit` already ran): write the entry plainly
      # rather than lose it.
      private def self.write_to_stderr(entry : LogEntry) : Nil
        STDERR.puts "#{entry.timestamp.to_rfc3339} #{entry.severity.label} #{entry.source}: #{entry.message}"
      end

      private def self.log_entry_by_severity(log : Log, entry : LogEntry)
        if exception = entry.exception
          log_with_exception(log, entry.severity, exception, entry.message)
        else
          log_without_exception(log, entry.severity, entry.message)
        end
      end

      private def self.log_with_exception(log : Log, severity : Log::Severity, exception : Exception, message : String)
        case severity
        when .debug? then log.debug(exception: exception) { message }
        when .info?  then log.info(exception: exception) { message }
        when .warn?  then log.warn(exception: exception) { message }
        when .error? then log.error(exception: exception) { message }
        when .fatal? then log.fatal(exception: exception) { message }
        else
          log.info(exception: exception) { message }
        end
      end

      private def self.log_without_exception(log : Log, severity : Log::Severity, message : String)
        case severity
        when .debug? then log.debug { message }
        when .info?  then log.info { message }
        when .warn?  then log.warn { message }
        when .error? then log.error { message }
        when .fatal? then log.fatal { message }
        else
          log.info { message }
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
          rescue ::Channel::ClosedError
            # `Log` is closed: the program is exiting
          rescue ex
            Log.for("Azu::AsyncLogging").error(exception: ex) { "Failed to send to external service" }
          end
        end
      end

      private def self.flush_pending_entries(queue : ::Channel(LogEntry))
        # Force flush any remaining entries in the queue
        pending = [] of LogEntry

        while pending.size < @@batch_size
          select
          when entry = queue.receive
            pending << entry
          else
            break
          end
        end

        process_batch(pending, -1) # -1 indicates flush worker
      end

      def self.running? : Bool
        !@@queue.closed?
      end
    end

    # Background error reporter
    class ErrorReporter
      @@error_queue = ::Channel(Exception).new(100)
      @@done = WaitGroup.new
      @@started = false
      @@start_lock = Mutex.new

      # Starts the reporter fiber. After `shutdown` it opens a new queue.
      def self.start
        @@start_lock.synchronize do
          return if @@started
          @@started = true
          @@error_queue = ::Channel(Exception).new(100) if @@error_queue.closed?
          queue = @@error_queue
          done = @@done = WaitGroup.new(1)
          spawn(name: "error-reporter") do
            error_processing_loop(queue)
          ensure
            done.done
          end
        end
        AsyncLogging.shutdown_at_exit
      end

      def self.report_error(exception : Exception)
        start unless @@error_queue.closed?
        @@error_queue.send(exception)
      rescue ::Channel::ClosedError
        # The reporter was shut down: report it now
        process_error(exception)
      end

      # Closes the queue and waits until every error it held has been reported. Safe to call again,
      # and when the reporter never started.
      def self.shutdown : Nil
        done = @@start_lock.synchronize do
          @@started = false
          @@error_queue.close
          @@done
        end
        done.wait
      end

      private def self.error_processing_loop(queue : ::Channel(Exception))
        while exception = queue.receive?
          process_error(exception)
        end
      end

      private def self.process_error(exception : Exception)
        # Enhanced error processing
        error_context = {
          "timestamp"   => Time.utc.to_rfc3339,
          "type"        => exception.class.name,
          "message"     => exception.message || "Unknown error",
          "backtrace"   => exception.backtrace?.try(&.first(20).join("\n")) || "No backtrace",
          "environment" => CONFIG.env.to_s,
        }

        # Log the error
        Log.for("Azu::ErrorReporter").error(exception: exception) {
          "Error processed: #{exception.class.name}"
        }

        # Send to external error reporting service
        send_to_error_service(exception, error_context)
      rescue ::Channel::ClosedError
        # `Log`'s async dispatcher is closed (its `at_exit` already ran)
        STDERR.puts "#{Time.utc.to_rfc3339} ERROR Azu::ErrorReporter: #{exception.class.name}: #{exception.message}"
      rescue ex
        STDERR.puts "Azu::ErrorReporter failed: #{ex.message}"
      end

      private def self.send_to_error_service(exception : Exception, context : Hash(String, String))
        return unless CONFIG.env.production?

        spawn(name: "external-error-sender") do
          begin
            # Example: Send to Sentry, Rollbar, etc.
            # ErrorReportingService.report(exception, context)
            Log.for("Azu::ErrorReporter").debug { "Error sent to external service" }
          rescue ::Channel::ClosedError
            # `Log` is closed: the program is exiting
          rescue ex
            Log.for("Azu::ErrorReporter").error(exception: ex) { "Failed to send error to external service" }
          end
        end
      end

      def self.running? : Bool
        !@@error_queue.closed?
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

    # Starts the workers now instead of on the first entry. Requiring azu starts nothing; the
    # first log entry or reported error starts the pipeline, and `App#start` calls this.
    def self.initialize
      BatchProcessor.start
      ErrorReporter.start
    end

    # Stops the pipeline and waits until every queued entry and reported error has been written.
    # Errors go first, as reporting one logs. Entries sent afterwards are written synchronously;
    # `initialize` (or `App#start`) starts the pipeline again. Safe to call again, and when the
    # pipeline never started. `Azu.shutdown` calls it, and so does an `at_exit` registered when the
    # pipeline first starts: that one runs before `Log`'s own `at_exit` (registered earlier, when
    # `log` was required) closes the async dispatcher the entries are written to.
    def self.shutdown : Nil
      ErrorReporter.shutdown
      BatchProcessor.shutdown
    end

    @@shutdown_at_exit = Atomic(Bool).new(false)

    # :nodoc:
    def self.shutdown_at_exit : Nil
      return if @@shutdown_at_exit.swap(true)
      at_exit { shutdown }
    end

    def self.running? : Bool
      BatchProcessor.running? && ErrorReporter.running?
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
