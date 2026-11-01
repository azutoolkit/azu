require "http"
require "mime/media_type"
require "./router"
require "./response"

module Azu
  # Request hygiene settings (`c.hygiene`).
  #
  # Controls body size limits (`413`), content-type enforcement (`415`), JSON-object body
  # validation (`422` vs `400`), and strict `X-Request-ID` validation.
  class HygieneConfiguration
    # Maximum request body size in bytes (`413 Payload Too Large` when exceeded).
    # When `nil`, falls back to `c.upload.max_file_size` inside `Params::Body.read`.
    property max_body_size : UInt64? = nil

    # When `true`, `Hygiene::BodyCheck` enforces `allowed_content_types` (`415 Unsupported Media Type`).
    property? strict_content_type : Bool = false

    # Media types accepted by `Hygiene::BodyCheck` when `strict_content_type` is enabled.
    property allowed_content_types : Array(String) = ["application/json"]

    # When `true`, `Params#typed_request` requires JSON bodies to be JSON objects (`{...}`),
    # treats empty or `null` bodies as `{}`, answers `422` (`validation_failed`) on non-object JSON
    # or `JSON::SerializableError`, and answers `malformed_json_status` (`invalid_json`) on syntax errors.
    property? require_json_object : Bool = false

    # HTTP status for syntactically invalid JSON when `require_json_object` is enabled (`400` by default, or `422`).
    property malformed_json_status : HTTP::Status = HTTP::Status::BAD_REQUEST

    # Stable error code for syntactically invalid JSON.
    property malformed_json_code : String = "invalid_json"

    # Error message for syntactically invalid JSON.
    property malformed_json_message : String = "Request body is not valid JSON"

    # Stable error code when a JSON body is valid JSON but not a JSON object.
    property non_object_json_code : String = "validation_failed"

    # Error message when a JSON body is valid JSON but not a JSON object.
    property non_object_json_message : String = "Request body must be a JSON object"

    # When `true`, `Handler::RequestId` only accepts client `X-Request-ID` values of `1..max_request_id_length`
    # matching `/\A[A-Za-z0-9._:-]+\z/`, replacing any other value with a generated ID.
    property? strict_request_id : Bool = false

    # Maximum length of an accepted client `X-Request-ID` when `strict_request_id` is enabled.
    property max_request_id_length : Int32 = 64
  end

  module Hygiene
    # Post-routing hook (`Router::Hook`) that enforces request body size limits (`413`) and
    # `Content-Type` checks (`415`) after `404`/`405` and `403` authorization, and before the action runs.
    class BodyCheck
      include Router::Hook

      BODY_METHODS = %w(POST PUT PATCH DELETE)

      # Wraps a request body IO to enforce a maximum byte limit as the body is read,
      # raising `Response::PayloadTooLarge` (`413`) at `limit + 1` bytes.
      class LimitedBodyIO < IO
        getter count : UInt64 = 0_u64

        def initialize(@io : IO, @limit : UInt64)
        end

        def read(slice : Bytes) : Int32
          allowed = @limit - Math.min(@count, @limit) + 1
          bytes_read = @io.read(slice[0, Math.min(slice.size.to_u64, allowed).to_i])
          @count += bytes_read.to_u64
          if @count > @limit
            raise Response::PayloadTooLarge.new(
              "Request body exceeds maximum allowed size of #{@limit} bytes"
            )
          end
          bytes_read
        end

        def peek : Bytes?
          data = @io.peek || return
          allowed = (@limit - Math.min(@count, @limit) + 1).to_i64
          data.size <= allowed ? data : data[0, allowed]
        end

        def write(slice : Bytes) : NoReturn
          raise IO::Error.new("Request body is read-only")
        end

        def close : Nil
          @io.close
          super
        end
      end

      def initialize(
        @config : Configuration? = nil,
        @max_body_size : UInt64? = nil,
        @strict_content_type : Bool? = nil,
        @allowed_content_types : Array(String)? = nil,
      )
      end

      def call(context : HTTP::Server::Context, route : Router::Route) : Nil
        cfg = (@config || Azu.current_config).hygiene
        check_body_size!(context.request, route, cfg)
        if strict_content_type?(cfg) || !route.content_types.nil?
          check_content_type!(context.request, route, cfg)
        end
      end

      private def strict_content_type?(cfg : HygieneConfiguration) : Bool
        if !(flag = @strict_content_type).nil?
          flag
        else
          cfg.strict_content_type?
        end
      end

      private def check_body_size!(request : HTTP::Request, route : Router::Route, cfg : HygieneConfiguration) : Nil
        limit = route.max_body_size || @max_body_size || cfg.max_body_size
        return unless limit

        if (declared = request.headers["Content-Length"]?.try(&.to_u64?)) && declared > limit
          raise Response::PayloadTooLarge.new(
            "Request body exceeds maximum allowed size of #{limit} bytes"
          )
        end

        if body = request.body
          if body.is_a?(IO::Memory) && (body.size - body.pos).to_u64 > limit
            raise Response::PayloadTooLarge.new(
              "Request body exceeds maximum allowed size of #{limit} bytes"
            )
          elsif !body.is_a?(LimitedBodyIO)
            request.body = LimitedBodyIO.new(body, limit)
          end
        end
      end

      private def check_content_type!(request : HTTP::Request, route : Router::Route, cfg : HygieneConfiguration) : Nil
        allowed = route.content_types || @allowed_content_types || cfg.allowed_content_types
        raw_ct = request.headers["Content-Type"]?
        has_payload = has_body?(request)
        is_body_method = BODY_METHODS.includes?(request.method.upcase)

        has_ct_header = !raw_ct.nil?
        return unless has_payload || (is_body_method && has_ct_header)

        if raw_ct.nil? || raw_ct.strip.empty?
          raise Response::UnsupportedMediaType.new("Unsupported Content-Type", allowed)
        end

        media_type = begin
          MIME::MediaType.parse(raw_ct).media_type.downcase
        rescue MIME::Error
          raise Response::UnsupportedMediaType.new("Unsupported Content-Type", allowed)
        end

        unless allowed.any? { |entry| entry.downcase == media_type }
          raise Response::UnsupportedMediaType.new("Unsupported Content-Type", allowed)
        end
      end

      private def has_body?(request : HTTP::Request) : Bool
        if cl = request.headers["Content-Length"]?.try(&.to_u64?)
          return cl > 0
        end
        return true if request.headers.has_key?("Transfer-Encoding")

        case body = request.body
        when IO::Memory
          body.size > body.pos
        when IO
          (peeked = body.peek) ? !peeked.empty? : false
        else
          false
        end
      end
    end
  end
end
