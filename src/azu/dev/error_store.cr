require "../exception_page"

module Azu
  # The server errors of the running app, for the dev dashboard's Errors tab: the latest `MAX_REPORTS` exception
  # reports in full (each one renders as the exception page again), grouped by fingerprint, with a count and first
  # and last time for every group. Fed by the `Instrumentation.on_exception` subscriber `azu/dev` registers, in
  # development only; bounded and thread-safe.
  class ErrorStore
    MAX_REPORTS     = 100
    MAX_GROUPS      = 200
    MAX_GROUP_TIMES = 500

    # One failure and how often it happened. `report_ids` lists the reports still kept, oldest first.
    record Group,
      fingerprint : String,
      exception_class : String,
      message : String,
      location : String?,
      route : String?,
      request_line : String,
      status : Int32,
      count : Int32,
      first_seen : Time,
      last_seen : Time,
      times : Array(Time),
      report_ids : Array(String) do
      def latest_id : String?
        report_ids.last?
      end
    end

    private class Entry
      property count : Int32 = 0
      getter times = Deque(Time).new
      getter first_seen : Time
      property latest : ExceptionPage::Report

      def initialize(@latest : ExceptionPage::Report)
        @first_seen = latest.timestamp
      end
    end

    @@instance = new

    def self.instance : ErrorStore
      @@instance
    end

    def initialize
      @mutex = Mutex.new
      @reports = Deque(ExceptionPage::Report).new
      @groups = {} of String => Entry
    end

    def record(report : ExceptionPage::Report) : Nil
      @mutex.synchronize do
        @reports << report
        @reports.shift if @reports.size > MAX_REPORTS
        entry = @groups[report.fingerprint] ||= Entry.new(report)
        entry.count += 1
        entry.latest = report
        entry.times << report.timestamp
        entry.times.shift if entry.times.size > MAX_GROUP_TIMES
        evict_oldest_group if @groups.size > MAX_GROUPS
      end
      report.recorded = true
    end

    def report(id : String) : ExceptionPage::Report?
      @mutex.synchronize { @reports.find { |report| report.id == id } }
    end

    def report_for_request(request_id : String) : ExceptionPage::Report?
      @mutex.synchronize { @reports.reverse_each.find { |report| report.request.id == request_id } }
    end

    # Newest first.
    def groups : Array(Group)
      @mutex.synchronize do
        @groups.values.sort_by!(&.latest.timestamp).reverse!.map { |entry| snapshot(entry) }
      end
    end

    def group(fingerprint : String) : Group?
      @mutex.synchronize { @groups[fingerprint]?.try { |entry| snapshot(entry) } }
    end

    # Where `report` stands among the kept reports of its fingerprint.
    def occurrence(report : ExceptionPage::Report) : ExceptionPage::Occurrence?
      @mutex.synchronize do
        entry = @groups[report.fingerprint]?
        return unless entry
        ids = kept_ids(report.fingerprint)
        position = ids.index(report.id)
        return unless position
        # The count covers reports no longer kept: number this one from the end.
        index = entry.count - (ids.size - 1 - position)
        previous_id = position > 0 ? ids[position - 1] : nil
        ExceptionPage::Occurrence.new(index, entry.count, previous_id, ids[position + 1]?, entry.first_seen)
      end
    end

    def size : Int32
      @mutex.synchronize { @groups.size }
    end

    def clear : Nil
      @mutex.synchronize do
        @reports.clear
        @groups.clear
      end
    end

    private def snapshot(entry : Entry) : Group
      report = entry.latest
      Group.new(report.fingerprint, report.exception_class, report.message, report.location.try(&.location),
        report.request.route, report.request.line, report.status, entry.count, entry.first_seen, report.timestamp,
        entry.times.to_a, kept_ids(report.fingerprint))
    end

    private def kept_ids(fingerprint : String) : Array(String)
      @reports.select { |report| report.fingerprint == fingerprint }.map(&.id)
    end

    private def evict_oldest_group : Nil
      oldest = @groups.min_by { |_, entry| entry.latest.timestamp }
      @groups.delete(oldest[0])
    end
  end
end
