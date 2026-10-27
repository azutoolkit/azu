require "base64"
require "digest/sha256"
require "html"
require "./value"

module Azu::OpenAPI
  # An HTML reference of a document, rendered on the server: no script and nothing loaded from elsewhere,
  # so its policy allows only its own style. Every value of the document is escaped.
  module DocsPage
    STYLE = <<-CSS
      body{font:15px/1.5 system-ui,sans-serif;margin:0 auto;max-width:960px;padding:1rem;color:#1f2328;background:#fff}
      @media (prefers-color-scheme:dark){body{color:#e6edf3;background:#0d1117}th,td{border-color:#30363d!important}}
      code{font:13px ui-monospace,monospace}table{border-collapse:collapse;width:100%;margin:.5rem 0}
      th,td{border:1px solid #d0d7de;padding:.25rem .5rem;text-align:left;vertical-align:top}
      .op,.schema{margin:1.5rem 0}.method{display:inline-block;min-width:4.5rem;font:bold 13px monospace;color:#fff;
      background:#57606a;border-radius:4px;text-align:center}.get{background:#0969da}.post{background:#1a7f37}
      .put,.patch{background:#9a6700}.delete{background:#cf222e}.muted{opacity:.7}
      CSS

    POLICY = "default-src 'none'; style-src 'sha256-#{Base64.strict_encode(Digest::SHA256.digest(STYLE))}'; " \
             "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    CONSTRAINTS = %w[minLength maxLength minItems maxItems minimum exclusiveMinimum maximum exclusiveMaximum pattern enum const]

    def self.render(document : Map, json_path : String) : String
      info = document["info"].as(Map)
      title = "#{info["title"]} #{info["version"]}"
      String.build do |html|
        html << %(<!doctype html><html lang="en"><head><meta charset="utf-8"><title>) << esc(title)
        html << "</title><style>" << STYLE << "</style></head><body><h1>" << esc(title) << "</h1>"
        info["description"]?.try { |description| html << "<p>" << esc(description.to_s) << "</p>" }
        html << %(<p class="muted">OpenAPI #{esc(document["openapi"].to_s)}: <a href=") << esc(json_path) << %(">) << esc(json_path) << "</a></p>"
        operations(html, document["paths"].as(Map))
        schemas(html, document["components"]?.try(&.as(Map)["schemas"]?.try(&.as(Map))) || Map.new)
        html << "</body></html>"
      end
    end

    private def self.operations(html : String::Builder, paths : Map) : Nil
      html << "<h2>Operations</h2>"
      paths.each do |path, item|
        item.as(Map).each do |method, operation|
          operation = operation.as(Map)
          html << %(<section class="op"><h3><span class="method ) << esc(method) << %(">) << esc(method.upcase)
          html << "</span> <code>" << esc(path) << "</code></h3><p class=\"muted\">" << esc(operation["operationId"].to_s) << "</p>"
          parameters(html, operation["parameters"]?.try(&.as(Array(Value))))
          body(html, operation["requestBody"]?.try(&.as(Map)))
          responses(html, operation["responses"].as(Map))
          html << "</section>"
        end
      end
    end

    private def self.parameters(html : String::Builder, parameters : Array(Value)?) : Nil
      return unless parameters
      html << "<table><tr><th>Parameter</th><th>In</th><th>Required</th><th>Schema</th></tr>"
      parameters.each do |parameter|
        parameter = parameter.as(Map)
        html << "<tr><td><code>" << esc(parameter["name"].to_s) << "</code></td><td>" << esc(parameter["in"].to_s)
        html << "</td><td>" << (parameter["required"]? == true ? "yes" : "no") << "</td><td>" << label(parameter["schema"]?) << "</td></tr>"
      end
      html << "</table>"
    end

    private def self.body(html : String::Builder, body : Map?) : Nil
      return unless body
      body["content"].as(Map).each do |media_type, content|
        html << "<p>Body <code>" << esc(media_type) << "</code></p>"
        properties(html, content.as(Map)["schema"]?.try(&.as(Map)) || Map.new)
      end
    end

    private def self.responses(html : String::Builder, responses : Map) : Nil
      html << "<table><tr><th>Status</th><th>Response</th></tr>"
      responses.each do |status, response|
        response = response.as(Map)
        html << "<tr><td>" << esc(status) << "</td><td>"
        if ref = response["$ref"]?
          html << esc(ref.to_s.split('/').last)
        else
          html << esc(response["description"]?.to_s)
          (response["content"]?.try(&.as(Map)) || Map.new).each do |media_type, content|
            html << "<br><code>" << esc(media_type) << "</code> " << label(content.as(Map)["schema"]?)
          end
        end
        html << "</td></tr>"
      end
      html << "</table>"
    end

    private def self.schemas(html : String::Builder, schemas : Map) : Nil
      return if schemas.empty?
      html << "<h2>Schemas</h2>"
      schemas.each do |name, schema|
        html << %(<section class="schema" id="schema-) << esc(name) << %("><h3>) << esc(name) << "</h3>"
        properties(html, schema.as(Map))
        html << "</section>"
      end
    end

    # The fields of an object schema as a table; any other schema as its label.
    private def self.properties(html : String::Builder, schema : Map) : Nil
      fields = schema["properties"]?.try(&.as(Map))
      unless fields
        html << "<p>" << label(schema) << "</p>"
        return
      end

      required = schema["required"]?.try(&.as(Array(Value))) || [] of Value
      html << "<table><tr><th>Field</th><th>Required</th><th>Schema</th></tr>"
      fields.each do |field, property|
        html << "<tr><td><code>" << esc(field) << "</code></td><td>" << (required.includes?(field) ? "yes" : "no")
        html << "</td><td>" << label(property) << "</td></tr>"
      end
      html << "</table>"
    end

    # A short, escaped description of a schema: `string, minLength 2`, `array of integer (int64)`, a link to a component.
    def self.label(schema : Value) : String
      schema = schema.as?(Map) || return "any"
      if ref = schema["$ref"]?
        name = esc(ref.to_s.split('/').last)
        return %(<a href="#schema-#{name}">#{name}</a>)
      end
      if variants = schema["anyOf"]?.try(&.as(Array(Value)))
        return variants.map { |variant| label(variant) }.join(" | ")
      end
      ([kind(schema)] + constraints(schema)).join(", ")
    end

    private def self.kind(schema : Map) : String
      case type = schema["type"]?
      when "array"  then "array of #{label(schema["items"]?)}"
      when "object" then schema["additionalProperties"]?.try { |values| "map of #{label(values)}" } || "object"
      when String   then schema["format"]?.try { |format| "#{esc(type)} (#{esc(format.to_s)})" } || esc(type)
      else               "any"
      end
    end

    private def self.constraints(schema : Map) : Array(String)
      CONSTRAINTS.compact_map { |name| schema[name]?.try { |value| "#{name} #{esc(value.is_a?(String) ? value : OpenAPI.encode(value))}" } }
    end

    private def self.esc(text : String) : String
      HTML.escape(text)
    end
  end
end
