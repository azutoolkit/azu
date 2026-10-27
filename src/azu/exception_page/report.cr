require "digest/sha1"
require "./frame"
require "./panel"

module Azu
  class ExceptionPage
    # An exception the exception wraps (`Exception#cause`), with the first frame of the app that raised it.
    record Cause, exception_class : String, message : String, location : Frame? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "class", exception_class
          json.field "message", message
          json.field "location", location
        end
      end
    end

    # The request that failed, every value already redacted (`Azu::Env.redact`): the report is shown and stored.
    record RequestInfo,
      id : String?,
      method : String,
      path : String,
      route : String?,
      elapsed_ms : Float64?,
      client : String?,
      user_agent : String?,
      referer : String?,
      params : Array({String, String}),
      headers : Array({String, String}),
      cookies : Array({String, String}),
      response_headers : Array({String, String}),
      response_cookies : Array({String, String}) do
      def line : String
        "#{method} #{path}"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", id
          json.field "method", method
          json.field "path", path
          json.field "route", route
          json.field "elapsed_ms", elapsed_ms.try(&.round(2))
        end
      end

      def self.blank : RequestInfo
        none = [] of {String, String}
        new(nil, "GET", "/", nil, nil, nil, nil, nil, none, none, none, none, none)
      end
    end

    # One `Report#id`'s place among the reports of its fingerprint, which the dashboard knows: `index` counts from 1,
    # oldest first.
    record Occurrence, index : Int32, total : Int32, previous_id : String?, next_id : String?, first_seen : Time

    # Everything the exception page shows about one failure, gathered once when it happens: the exception and its
    # causes, the parsed backtrace, the redacted request, the likely causes (`Triage`) and the signals the panel
    # providers saw. It holds no reference to the request, so the dev dashboard can keep it and show it again.
    class Report
      MAX_CAUSES = 5

      getter id : String = Random::Secure.hex(8)
      getter timestamp : Time = Time.utc
      getter status : Int32
      getter exception_class : String
      getter message : String
      getter frames : Array(Frame)
      getter causes : Array(Cause)
      getter request : RequestInfo
      getter fingerprint : String
      getter error_id : String?
      getter panels : Array(Panel) = [] of Panel
      getter hints : Array(Hint) = [] of Hint
      # Set by a store that keeps the report (the dev dashboard), so pages can link to it.
      property? recorded : Bool = false

      def initialize(@status, @exception_class, @message, @frames, @causes, @request, @error_id = nil)
        @fingerprint = Report.fingerprint(@exception_class, @frames, @message)
      end

      # The report for `exception` answered with `status`. A `Response::Error` made from another exception
      # (`Error.from_exception`) is reported as that exception, so the page shows what was raised.
      def self.build(exception : Exception, context : HTTP::Server::Context? = nil, status : Int32 = 500,
                     error_id : String? = nil) : Report
        primary = exception.is_a?(Response::Error) ? (exception.cause || exception) : exception
        report = new(status, primary.class.name, message_of(primary), Frame.parse_all(primary.backtrace?),
          causes_of(primary), context ? request_info(context) : RequestInfo.blank, error_id)
        report.investigate(primary)
        report
      end

      # Runs the panel providers and the triage rules. Neither can break the page: a failing one is skipped.
      def investigate(exception : Exception) : Nil
        @panels = ExceptionPage.panels_for(self)
        @hints = ExceptionPage.hints_for(exception, self)
      end

      # The first frame of the app, else the first frame with a location.
      def location : Frame?
        frames.find(&.app?) || frames.find(&.line)
      end

      def app_frames : Array(Frame)
        frames.select(&.app?)
      end

      def status_text : String
        HTTP::Status.from_value?(status).try(&.description) || "Error"
      end

      def dashboard_url : String?
        return unless recorded?
        ExceptionPage.dashboard_path.try { |path| "#{path}/errors/#{id}" }
      end

      # Plain text to paste into an issue or a chat: what failed, where, the likely causes and the app frames.
      def to_markdown : String
        String.build do |io|
          io << "## " << exception_class << ": " << message.lines.first? << "\n\n"
          io << "- Request: `" << request.line << "`"
          request.route.try { |route| io << " (" << route << ")" }
          io << " → " << status << ' ' << status_text << '\n'
          location.try { |frame| io << "- Raised in: `" << frame.location << "`" << (frame.method.try { |name| " in `#{name}`" }) << '\n' }
          request.id.try { |id| io << "- Request ID: `" << id << "`\n" }
          unless hints.empty?
            io << "\n### Likely causes\n\n"
            hints.each { |hint| io << "- **" << hint.title << "**: " << hint.detail << '\n' }
          end
          io << "\n### Backtrace\n\n```\n"
          (app_frames.empty? ? frames.first(10) : app_frames).each { |frame| io << frame.raw << '\n' }
          io << "```\n"
          causes.each { |cause| io << "\nCaused by " << cause.exception_class << ": " << cause.message << '\n' }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", id
          json.field "class", exception_class
          json.field "message", message
          json.field "fingerprint", fingerprint
          json.field "location", location
          json.field "hints", hints
          json.field "frames" do
            json.array do
              others = 0
              frames.each do |frame|
                next unless frame.app? || (others += 1) <= 20
                frame.to_json(json)
              end
            end
          end
          json.field "causes", causes
          json.field "request", request
          json.field "signals", panels
          json.field "dashboard_url", dashboard_url
        end
      end

      # Groups occurrences of one failure: the class and where in the app it was raised (messages carry ids and
      # values), the message when no frame says where.
      def self.fingerprint(exception_class : String, frames : Array(Frame), message : String) : String
        frame = frames.find(&.app?) || frames.find(&.line)
        where = frame ? "#{frame.file}:#{frame.line}" : message
        Digest::SHA1.hexdigest("#{exception_class}:#{where}")[0, 16]
      end

      private def self.message_of(exception : Exception) : String
        text = if exception.is_a?(Response::Error)
                 exception.detail.presence || exception.title
               else
                 exception.message.presence || exception.class.name
               end
        Azu::Env.redact_url(text)
      end

      private def self.causes_of(exception : Exception) : Array(Cause)
        causes = [] of Cause
        cause = exception.cause
        while cause && causes.size < MAX_CAUSES
          frames = Frame.parse_all(cause.backtrace?)
          causes << Cause.new(cause.class.name, message_of(cause), frames.find(&.app?) || frames.find(&.line))
          cause = cause.cause
        end
        causes
      end

      private def self.request_info(context : HTTP::Server::Context) : RequestInfo
        request = context.request
        info = RequestContext.current?
        RequestInfo.new(
          id: info.try(&.request_id) || request.headers["X-Request-ID"]?,
          method: request.method,
          path: Azu::Env.redact_url(request.resource),
          route: info.try(&.endpoint) || request.headers["X-Azu-Endpoint"]?,
          elapsed_ms: info.try { |current| (Time.instant - current.started_at).total_milliseconds },
          client: request.remote_address.try(&.to_s),
          user_agent: request.headers["User-Agent"]?,
          referer: request.headers["Referer"]?.try { |value| Azu::Env.redact_url(value) },
          params: redact_pairs(request.query_params.map { |name, value| {name, value} }),
          headers: redact_pairs(request.headers.flat_map { |name, values| values.map { |value| {name, value} } }),
          cookies: redact_pairs(request.cookies.map { |cookie| {cookie.name, cookie.value} }),
          response_headers: redact_pairs(context.response.headers.flat_map { |name, values| values.map { |value| {name, value} } }),
          response_cookies: redact_pairs(context.response.cookies.map { |cookie| {cookie.name, cookie.value} }),
        )
      end

      BUNDLED = {"cookie", "set-cookie"}

      # The `Cookie` and `Set-Cookie` headers bundle every cookie value, whatever its name, so they are replaced
      # whole; the cookies are listed one by one instead, each redacted by its own name.
      private def self.redact_pairs(pairs : Array({String, String})) : Array({String, String})
        pairs.map do |name, value|
          {name, BUNDLED.includes?(name.downcase) ? Azu::Env::REDACTED : Azu::Env.redact(name, value)}
        end
      end
    end
  end
end
