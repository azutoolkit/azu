require "log"

module Azu
  # What the framework writes into a log line about a request: text a client chose (the path, an error detail) is
  # cut to a length and stripped of control characters, so one request cannot forge or flood log lines.
  module LogText
    MAX_LENGTH = 200

    def self.safe(value : String, limit : Int32 = MAX_LENGTH) : String
      text = value.size > limit ? "#{value[0, limit]}..." : value
      text.gsub(/[\x00-\x1f\x7f]/) { |char| "\\x%02x" % char.bytes.first }
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

    def self.client_error_line(method : String, path : String, status : Int32, title : String, detail : String? = nil) : String
      line = "#{method} #{safe(path)} -> #{status} #{title}"
      detail && !detail.empty? && detail != title ? "#{line}: #{safe(detail)}" : line
    end
  end
end
