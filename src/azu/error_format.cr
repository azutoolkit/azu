require "http/server"

module Azu
  # How request and routing errors are serialized for JSON clients.
  enum ErrorFormat
    # RFC 7807 problem body (`application/problem+json` when the client names it in `Accept`) with the failing fields under `errors`.
    Problem
    # Structured JSON envelope (`{"error": {"code": ..., "message": ..., "details": ..., "request_id": ...}}` by default).
    Envelope
    # The body of Azu before 0.6, kept for backward compatibility.
    Legacy
  end

  # How contract validation failures (`422`) populate messages and field details.
  enum ValidationErrorMode
    # Include every failing rule message per field.
    All
    # Include only the first failing message (and use it as the primary error message in Envelope mode).
    FirstMessageOnly
  end

  # Configuration for `ErrorFormat::Envelope` and custom error rendering (`config.error_envelope`).
  class ErrorEnvelopeConfiguration
    # Top-level JSON key wrapping the error object. Set to `nil` for a flat envelope
    # (`{"code": ..., "message": ..., "details": ..., "request_id": ...}`).
    property wrapper_key : String? = "error"

    # Controls whether `422 ValidationError` reports all field messages or only the first message.
    property validation_mode : ValidationErrorMode = ValidationErrorMode::All

    # Optional custom error renderer called by `Response::Error#to_s(context)`.
    property renderer : Proc(HTTP::Server::Context, Response::Error, Nil)? = nil
  end
end
