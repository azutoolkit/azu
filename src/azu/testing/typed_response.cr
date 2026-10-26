require "./response"

module Azu
  module Testing
    # `TypedResponse#value` was asked of a response whose status is not a success.
    class UnexpectedStatus < Exception
      getter response : Response

      def initialize(@response : Response)
        super("Expected a successful response, got #{response.status_code}: #{response.body[0, 200]}")
      end
    end

    # What a typed call (`client.post(UserEndpoint, request)`) got back: the `Response`, which every
    # method of it reaches, and `value`, the body decoded as the endpoint's response type `T`.
    struct TypedResponse(T)
      getter response : Response

      forward_missing_to @response

      def initialize(@response : Response)
      end

      def to_s(io : IO) : Nil
        @response.to_s(io)
      end

      def inspect(io : IO) : Nil
        @response.inspect(io)
      end

      # The body as a `T`. Raises `UnexpectedStatus` unless the status is a 2xx (and `JSON::ParseException` for a 2xx
      # whose body is not a `T`, such as an empty 204); a `T` that is not `JSON::Serializable` does not compile, since
      # nothing says how to read it back.
      def value : T
        {% unless (T.union? ? T.union_types : [T]).all? { |type| type <= JSON::Serializable } %}
          {% raise "#{T} is not JSON::Serializable: read the body of the response instead of its value" %}
        {% end %}
        raise UnexpectedStatus.new(@response) unless @response.success?
        T.from_json(@response.body)
      end
    end
  end
end
