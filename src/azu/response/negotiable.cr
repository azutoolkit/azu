module Azu::Response
  # A response that renders itself in several formats and lets the request's `Accept` header pick one.
  # Define `render_html`, `render_json`, `render_xml` and `render_text` (any of them, each returning a
  # String); the module finds the ones that exist.
  #
  # ```
  # struct UserPage
  #   include Azu::Response::Negotiable
  #
  #   def initialize(@name : String)
  #   end
  #
  #   def render_html : String
  #     "<h1>#{HTML.escape(@name)}</h1>"
  #   end
  #
  #   def render_json : String
  #     {name: @name}.to_json
  #   end
  # end
  # ```
  #
  # A request without `Accept`, or accepting `*/*`, gets the first format: HTML, JSON, XML, text,
  # unless `prefer :json, :html` says otherwise. A client that accepts none of them gets a 406
  # (`Response::NotAcceptable`); an endpoint declared with the response type refuses it before `call`
  # runs, so nothing is done for a request that cannot be answered. `?format=json` overrides the header.
  # The response carries `Vary: Accept`.
  module Negotiable
    include Azu::Response

    macro included
      # The formats this type renders, the preferred ones first.
      def self.formats : Array(Azu::Negotiation::Format)
        formats = [] of Azu::Negotiation::Format
        \{% for name in %w(html json xml text) %}
          \{% if @type.has_method?("render_#{name.id}") %}
            formats << Azu::Negotiation::Format::\{{ name.capitalize.id }}
          \{% end %}
        \{% end %}
        preferred.select { |format| formats.includes?(format) } + (formats - preferred)
      end

      # The formats `formats` lists first, set with `prefer`.
      def self.preferred : Array(Azu::Negotiation::Format)
        [] of Azu::Negotiation::Format
      end
    end

    # Makes the given formats the first ones, in this order: `prefer :json, :html`.
    macro prefer(*names)
      def self.preferred : Array(Azu::Negotiation::Format)
        [{% for name in names %}Azu::Negotiation::Format::{{ name.id.capitalize }}, {% end %}] of Azu::Negotiation::Format
      end
    end

    def formats : Array(Azu::Negotiation::Format)
      self.class.formats
    end

    # Renders in the format the request accepts. Without a request, in the first format.
    def render : String
      render_as(formats.first)
    end

    def render_as(format : Azu::Negotiation::Format) : String
      {% for name in %w(html json xml text) %}
        {% if @type.has_method?("render_#{name.id}") %}
          return render_{{ name.id }}.to_s if format.{{ name.id }}?
        {% end %}
      {% end %}
      raise ArgumentError.new("#{self.class} does not render #{format.media_type}")
    end

    def write_to(context : HTTP::Server::Context) : Nil
      format = Negotiation.negotiate!(formats, context.request)
      Negotiation.vary(context.response)
      context.response.content_type = format.content_type
      context.response << render_as(format)
    end
  end
end
