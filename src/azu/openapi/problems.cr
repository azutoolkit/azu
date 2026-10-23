require "./value"

module Azu::OpenAPI
  # The error bodies Azu answers with, described once as shared components:
  #
  # * `Azu.ValidationProblem`: the RFC 7807 `application/problem+json` body of a 422, as
  #   `Response::ValidationError#json` writes it;
  # * `Azu.Error`: the body every other `Response::Error` (400, 404 and the rest) writes when the
  #   client accepts JSON.
  module Problems
    VALIDATION = "Azu.ValidationProblem"
    ERROR      = "Azu.Error"

    BAD_REQUEST       = "BadRequest"
    NOT_FOUND         = "NotFound"
    VALIDATION_FAILED = "ValidationFailed"

    def self.schemas : Map
      Map{
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
            "Status"      => Map{"type" => "string"},
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

    def self.responses : Map
      Map{
        BAD_REQUEST       => response("The request could not be parsed.", "application/json", ERROR),
        NOT_FOUND         => response("Nothing is routed there, or the endpoint found nothing.", "application/json", ERROR),
        VALIDATION_FAILED => response("The request broke its contract.", "application/problem+json", VALIDATION),
      }
    end

    def self.reference(name : String) : Map
      Map{"$ref" => "#/components/responses/#{name}"}
    end

    private def self.response(description : String, media_type : String, schema : String) : Map
      Map{
        "description" => description,
        "content"     => Map{media_type => Map{"schema" => Map{"$ref" => "#/components/schemas/#{schema}"}}},
      }
    end
  end
end
