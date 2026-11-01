require "./value"

module Azu::OpenAPI
  # The error bodies Azu answers with, described once as shared components:
  #
  # * `Azu.ValidationProblem`: the RFC 7807 `application/problem+json` body of a 422, as
  #   `Response::ValidationError#json` writes it (also sent as `application/json` to a client that does not
  #   name problem+json in Accept);
  # * `Azu.Error`: the `application/problem+json` body every other `Response::Error` (400, 404 and the
  #   rest) writes when the client accepts JSON;
  # * `Azu.LegacyValidationError` and `Azu.LegacyError`: the `application/json` bodies of an app with
  #   `error_format = Legacy`, in place of `Azu.ValidationProblem` and `Azu.Error`.
  module Problems
    VALIDATION   = "Azu.ValidationProblem"
    ERROR        = "Azu.Error"
    LEGACY       = "Azu.LegacyValidationError"
    LEGACY_ERROR = "Azu.LegacyError"
    ENVELOPE     = "Azu.ErrorEnvelope"

    # The same body is sent as `application/problem+json` to a client that names it in Accept and as
    # `application/json` to any other.
    PROBLEM_MEDIA_TYPES = ["application/problem+json", "application/json"]

    BAD_REQUEST            = "BadRequest"
    UNAUTHORIZED           = "Unauthorized"
    FORBIDDEN              = "Forbidden"
    NOT_FOUND              = "NotFound"
    METHOD_NOT_ALLOWED     = "MethodNotAllowed"
    PAYLOAD_TOO_LARGE      = "PayloadTooLarge"
    UNSUPPORTED_MEDIA_TYPE = "UnsupportedMediaType"
    VALIDATION_FAILED      = "ValidationFailed"

    # The name of the schema the 422 response uses.
    def self.validation_schema(legacy : Bool) : String
      legacy ? LEGACY : VALIDATION
    end

    def self.validation_schema(format : ErrorFormat) : String
      case format
      when .legacy?   then LEGACY
      when .envelope? then ENVELOPE
      else                 VALIDATION
      end
    end

    # The name of the schema the other error responses use.
    def self.error_schema(legacy : Bool) : String
      legacy ? LEGACY_ERROR : ERROR
    end

    def self.error_schema(format : ErrorFormat) : String
      case format
      when .legacy?   then LEGACY_ERROR
      when .envelope? then ENVELOPE
      else                 ERROR
      end
    end

    def self.schemas : Map
      Map{
        LEGACY => Map{
          "type"       => "object",
          "properties" => Map{
            "Status"      => status_schema,
            "Title"       => Map{"type" => "string"},
            "Detail"      => Map{"type" => "string"},
            "FieldErrors" => Map{
              "type"                 => "object",
              "additionalProperties" => Map{"type" => "array", "items" => Map{"type" => "string"}},
            },
            "ErrorId"     => Map{"type" => "string"},
            "Fingerprint" => Map{"type" => "string"},
            "Context"     => Map{"type" => ["object", "null"] of Value},
            "Timestamp"   => Map{"type" => "string", "format" => "date-time"},
          },
        },
        VALIDATION => Map{
          "type"       => "object",
          "properties" => Map{
            "type"     => Map{"type" => "string"},
            "title"    => Map{"type" => "string"},
            "status"   => Map{"type" => "integer"},
            "detail"   => Map{"type" => "string"},
            "instance" => Map{"type" => "string", "description" => "The request path."},
            "errors"   => Map{
              "type"                 => "object",
              "additionalProperties" => Map{"type" => "array", "items" => Map{"type" => "string"}},
            },
          },
          "required" => ["type", "title", "status", "detail", "errors"] of Value,
        },
        ERROR => Map{
          "type"       => "object",
          "properties" => Map{
            "type"      => Map{"type" => "string"},
            "title"     => Map{"type" => "string"},
            "status"    => Map{"type" => "integer"},
            "detail"    => Map{"type" => "string"},
            "instance"  => Map{"type" => "string", "description" => "The request path."},
            "errors"    => Map{"type" => "array", "items" => Map{"type" => "string"}},
            "error_id"  => Map{"type" => "string"},
            "context"   => Map{"type" => "object", "description" => "Development only."},
            "backtrace" => Map{"type" => "string", "description" => "Development only."},
          },
          "required" => ["type", "title", "status", "detail", "errors", "error_id"] of Value,
        },
        LEGACY_ERROR => Map{
          "type"       => "object",
          "properties" => Map{
            "Status"      => status_schema,
            "Link"        => Map{"type" => "string"},
            "Title"       => Map{"type" => "string"},
            "Detail"      => Map{"type" => "string"},
            "Source"      => Map{"type" => "string"},
            "Errors"      => Map{"type" => "array", "items" => Map{"type" => "string"}},
            "ErrorId"     => Map{"type" => "string"},
            "Fingerprint" => Map{"type" => "string"},
            "Context"     => Map{"type" => ["object", "null"] of Value},
            "Backtrace"   => Map{"type" => ["string", "null"] of Value},
            "Timestamp"   => Map{"type" => "string", "format" => "date-time"},
          },
        },
        ENVELOPE => envelope_schema,
      }
    end

    def self.envelope_schema(wrapper_key : String? = "error") : Map
      inner = Map{
        "type"       => "object",
        "properties" => Map{
          "code"       => Map{"type" => "string"},
          "message"    => Map{"type" => "string"},
          "details"    => Map{"type" => ["object", "array", "string", "null"] of Value},
          "request_id" => Map{"type" => "string"},
        },
        "required" => ["code", "message"] of Value,
      }
      if key = wrapper_key
        Map{
          "type"       => "object",
          "properties" => Map{key => inner},
          "required"   => [key] of Value,
        }
      else
        inner
      end
    end

    def self.responses(legacy : Bool = false) : Map
      responses(legacy ? ErrorFormat::Legacy : ErrorFormat::Problem)
    end

    def self.responses(format : ErrorFormat) : Map
      media_types = (format.legacy? || format.envelope?) ? ["application/json"] : PROBLEM_MEDIA_TYPES
      err_schema = error_schema(format)
      val_schema = validation_schema(format)

      Map{
        BAD_REQUEST            => response("The request could not be parsed.", media_types, err_schema),
        UNAUTHORIZED           => response_with_headers("Authentication is required or failed.", media_types, err_schema, Map{"WWW-Authenticate" => Map{"schema" => Map{"type" => "string"}}}),
        FORBIDDEN              => response("The authenticated principal is not allowed to perform this action.", media_types, err_schema),
        NOT_FOUND              => response("Nothing is routed there, or the endpoint found nothing.", media_types, err_schema),
        METHOD_NOT_ALLOWED     => response_with_headers("The HTTP method is not allowed for this resource.", media_types, err_schema, Map{"Allow" => Map{"schema" => Map{"type" => "string"}}}),
        PAYLOAD_TOO_LARGE      => response("The request body exceeds the maximum allowed size.", media_types, err_schema),
        UNSUPPORTED_MEDIA_TYPE => response_with_headers("The request Content-Type is not supported.", media_types, err_schema, Map{"Accept" => Map{"schema" => Map{"type" => "string"}}, "Accept-Post" => Map{"schema" => Map{"type" => "string"}}}),
        VALIDATION_FAILED      => response("The request broke its contract.", media_types, val_schema),
      }
    end

    def self.reference(name : String) : Map
      Map{"$ref" => "#/components/responses/#{name}"}
    end

    # `Response::Error` writes the `HTTP::Status` member name, underscored.
    private def self.status_schema : Map
      Map{"type" => "string", "description" => "The HTTP::Status member name, underscored, such as not_found."}
    end

    private def self.error_response(description : String, legacy : Bool) : Map
      response(description, legacy ? ["application/json"] : PROBLEM_MEDIA_TYPES, error_schema(legacy))
    end

    private def self.response_with_headers(description : String, media_types : Array(String), schema : String, headers : Map) : Map
      res = response(description, media_types, schema)
      res["headers"] = headers
      res
    end

    private def self.response(description : String, media_types : Array(String), schema : String) : Map
      content = Map.new
      media_types.each { |media_type| content[media_type] = Map{"schema" => Map{"$ref" => "#/components/schemas/#{schema}"}} }
      Map{"description" => description, "content" => content}
    end
  end
end
