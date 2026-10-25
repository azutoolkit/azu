require "./value"

module Azu::OpenAPI
  # The error bodies Azu answers with, described once as shared components:
  #
  # * `Azu.ValidationProblem`: the RFC 7807 `application/problem+json` body of a 422, as
  #   `Response::ValidationError#json` writes it;
  # * `Azu.Error`: the `application/problem+json` body every other `Response::Error` (400, 404 and the
  #   rest) writes when the client accepts JSON;
  # * `Azu.LegacyValidationError` and `Azu.LegacyError`: the `application/json` bodies of an app with
  #   `error_format = Legacy`, in place of `Azu.ValidationProblem` and `Azu.Error`.
  module Problems
    VALIDATION   = "Azu.ValidationProblem"
    ERROR        = "Azu.Error"
    LEGACY       = "Azu.LegacyValidationError"
    LEGACY_ERROR = "Azu.LegacyError"

    BAD_REQUEST       = "BadRequest"
    NOT_FOUND         = "NotFound"
    VALIDATION_FAILED = "ValidationFailed"

    # The name of the schema the 422 response uses.
    def self.validation_schema(legacy : Bool) : String
      legacy ? LEGACY : VALIDATION
    end

    # The name of the schema the other error responses use.
    def self.error_schema(legacy : Bool) : String
      legacy ? LEGACY_ERROR : ERROR
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
            "type"   => Map{"type" => "string"},
            "title"  => Map{"type" => "string"},
            "status" => Map{"type" => "integer"},
            "detail" => Map{"type" => "string"},
            "errors" => Map{
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
            "instance"  => Map{"type" => "string", "description" => "The request path, when the error knows it."},
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
      }
    end

    def self.responses(legacy : Bool = false) : Map
      Map{
        BAD_REQUEST       => error_response("The request could not be parsed.", legacy),
        NOT_FOUND         => error_response("Nothing is routed there, or the endpoint found nothing.", legacy),
        VALIDATION_FAILED => legacy ? response("The request broke its contract.", "application/json", LEGACY) : response("The request broke its contract.", "application/problem+json", VALIDATION),
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
      response(description, legacy ? "application/json" : "application/problem+json", error_schema(legacy))
    end

    private def self.response(description : String, media_type : String, schema : String) : Map
      Map{
        "description" => description,
        "content"     => Map{media_type => Map{"schema" => Map{"$ref" => "#/components/schemas/#{schema}"}}},
      }
    end
  end
end
