require "log"

module Azu
  # What the framework writes into a log line about a request: text a client chose (the path, an error detail) is
  # cut to a length and stripped of control characters, so one request cannot forge or flood log lines.
  module LogText
    # An access line keeps long targets (OAuth callbacks, searches); the reason text of a 4xx is cut shorter.
    MAX_LENGTH    = 2048
    REASON_LENGTH =  200

    # C0 and C1 controls, line/paragraph separators and bidi overrides/isolates: they forge or reorder log lines.
    UNSAFE = /[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}\x{202a}-\x{202e}\x{2066}-\x{2069}]/

    def self.safe(value : String, limit : Int32 = MAX_LENGTH) : String
      text = value.size > limit ? "#{value[0, limit]}..." : value
      text.gsub(UNSAFE) do |char|
        code = char[0].ord
        code < 0x100 ? "\\x%02x" % code : "\\u%04x" % code
      end
    end

    # A request target for the access line: credential-looking query parameters are replaced (`?token=...`).
    def self.target(resource : String) : String
      safe(Azu::Env.redact_url(resource))
    end

    # How loud a 4xx is: the router's 404 and most client mistakes are debug (the request log has the access line),
    # but 401, 403, 413 and 429 are what an operator wants to see at the default level.
    def self.client_error_severity(status : Int32) : Log::Severity
      case status
      when 403, 429 then Log::Severity::Warn
      when 401, 413 then Log::Severity::Info
      else               Log::Severity::Debug
      end
    end

    # Writes the block's line at the severity of `status`.
    def self.log_client_error(log : ::Log, status : Int32, &block : -> String) : Nil
      case client_error_severity(status)
      when .warn? then log.warn(&block)
      when .info? then log.info(&block)
      else             log.debug(&block)
      end
    end

    # The line for a refusal a handler wrote itself (CSRF, CORS, Throttle, IpSpoofing), as the `Rescuer` writes a 4xx.
    def self.log_refusal(log : ::Log, request : HTTP::Request, error : Azu::Response::Error) : Nil
      log_client_error(log, error.status_code) do
        client_error_line(request.method, request.path, error.status_code, error.title, error.detail)
      end
    end

    def self.client_error_line(method : String, path : String, status : Int32, title : String, detail : String? = nil) : String
      line = "#{method} #{safe(path, REASON_LENGTH)} -> #{status} #{title}"
      detail && !detail.empty? && detail != title ? "#{line}: #{safe(detail, REASON_LENGTH)}" : line
    end
  end
end
