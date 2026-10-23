require "./schema"

module Azu::OpenAPI
  # What an endpoint contributes to a document, independent of the route it is served at: its
  # request fields as an object schema and the schema of its response. Where the fields go (path,
  # query or body) depends on the HTTP method and the path, which only the route knows.
  record Operation,
    operation_id : String,
    tags : Array(String),
    request_schema : Map?,
    form_schema : Map?,
    response_schema : Map?,
    components : Components,
    response_types : Array(String) = [] of String do
    # The operation of an endpoint of type `endpoint` with the given request and response types.
    # A request that is not a `JSON::Serializable` struct (the bare `Azu::Request`) declares no fields,
    # and a response that is not one has no schema: nothing says what it renders.
    def self.of(endpoint : E.class, request : Req.class, response : Res.class) : Operation forall E, Req, Res
      components = Components.new
      new(
        operation_id: OpenAPI.identifier(E.name),
        tags: tags_of(E.name),
        request_schema: described?(Req) ? Schema.object(Req, components) : nil,
        form_schema: described?(Req) ? Schema.object(Req, components, Schema::Form) : nil,
        response_schema: described?(Res) ? Schema.of(Res, components) : nil,
        components: components,
        response_types: negotiated_types(Res),
      )
    end

    # The namespace an endpoint is declared in groups its operations: `Shop::Users::ShowEndpoint` is tagged `Users`.
    def self.tags_of(name : String) : Array(String)
      namespace = name.split("::")[...-1]
      namespace.empty? ? [] of String : [namespace.last]
    end

    # The media types a `Response::Negotiable` (or a union of them) renders; none for any other response.
    private def self.negotiated_types(type : T.class) : Array(String) forall T
      {% begin %}
        {% types = T.union? ? T.union_types : [T] %}
        {% if types.all? { |type| type <= Azu::Response::Negotiable } %}
          {% if T.union? %}
            formats = [] of Azu::Negotiation::Format
            {% for type in types %}
              formats.concat({{ type }}.formats)
            {% end %}
            formats.uniq.map(&.media_type)
          {% else %}
            T.formats.map(&.media_type)
          {% end %}
        {% else %}
          [] of String
        {% end %}
      {% end %}
    end

    private def self.described?(type : T.class) : Bool forall T
      {{ T < JSON::Serializable }}
    end
  end
end
