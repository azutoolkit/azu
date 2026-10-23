require "json"

# A cheap structural check of an OpenAPI 3.1 document: the rules a generator can get wrong, not the
# whole specification. Returns the problems found, empty for a document that passes.
module OpenAPIValidator
  PATH_ITEM_KEYS = %w(get put post delete options head patch trace parameters summary description servers $ref)
  OPERATIONS     = %w(get put post delete options head patch trace)
  NO_BODY        = %w(get delete head)
  TYPES          = %w(string number integer boolean array object null)

  def self.problems(document : JSON::Any) : Array(String)
    problems = [] of String
    root = document.as_h? || return ["the document is not an object"]

    problems << "openapi must be a 3.1.x version" unless root["openapi"]?.try(&.as_s?).try(&.starts_with?("3.1."))
    problems << "info.title is missing" unless root["info"]?.try(&.["title"]?).try(&.as_s?)
    problems << "info.version is missing" unless root["info"]?.try(&.["version"]?).try(&.as_s?)
    problems << "one of paths, components or webhooks is required" unless %w(paths components webhooks).any? { |key| root.has_key?(key) }

    check_paths(root["paths"]?, problems)
    check_references(document, document, "#", problems)
    check_component_names(root["components"]?, problems)
    check_types(document, "#", problems)
    problems
  end

  private def self.check_paths(paths : JSON::Any?, problems : Array(String)) : Nil
    return unless paths
    operation_ids = Set(String).new

    paths.as_h.each do |path, item|
      problems << "path #{path} must start with /" unless path.starts_with?('/')
      item.as_h.each_key { |key| problems << "#{path}: #{key} is not a path item field" unless PATH_ITEM_KEYS.includes?(key) }
      shared = item["parameters"]?.try(&.as_a) || [] of JSON::Any

      item.as_h.each do |verb, operation|
        next unless OPERATIONS.includes?(verb)
        where = "#{verb.upcase} #{path}"
        check_operation(where, path, verb, operation, shared, operation_ids, problems)
      end
    end
  end

  private def self.check_operation(where, path, verb, operation : JSON::Any, shared, operation_ids, problems) : Nil
    problems << "#{where}: responses is required" if operation["responses"]?.try(&.as_h?).try(&.empty?) != false

    operation["responses"]?.try(&.as_h?).try &.each_key do |status|
      problems << "#{where}: #{status} is not a status code" unless status == "default" || status.matches?(/\A[1-5](\d\d|XX)\z/)
    end

    if id = operation["operationId"]?.try(&.as_s)
      problems << "#{where}: operationId #{id} is not unique" unless operation_ids.add?(id)
    end

    problems << "#{where}: #{verb} must not have a requestBody" if NO_BODY.includes?(verb) && operation["requestBody"]?

    parameters = shared + (operation["parameters"]?.try(&.as_a) || [] of JSON::Any)
    seen = Set(String).new
    parameters.each do |parameter|
      next if parameter["$ref"]?
      key = "#{parameter["in"]?}:#{parameter["name"]?}"
      problems << "#{where}: parameter #{key} is declared twice" unless seen.add?(key)
      problems << "#{where}: parameter #{key} needs a schema" unless parameter["schema"]? || parameter["content"]?
      problems << "#{where}: path parameter #{key} must be required" if parameter["in"]?.try(&.as_s) == "path" && parameter["required"]? != true
    end

    declared = parameters.select { |parameter| parameter["in"]?.try(&.as_s) == "path" }.map { |parameter| parameter["name"].as_s }
    templated = path.scan(/\{([^}]+)\}/).map(&.[1])
    (templated - declared).each { |name| problems << "#{where}: path parameter #{name} is not declared" }
    (declared - templated).each { |name| problems << "#{where}: #{name} is declared but not in the path" }
  end

  # Every "$ref" is a local JSON pointer that must lead somewhere.
  private def self.check_references(root : JSON::Any, node : JSON::Any, at : String, problems : Array(String)) : Nil
    if hash = node.as_h?
      if ref = hash["$ref"]?.try(&.as_s?)
        problems << "#{at}: $ref #{ref} does not resolve" unless resolve(root, ref)
      end
      hash.each { |key, child| check_references(root, child, "#{at}/#{key}", problems) }
    elsif array = node.as_a?
      array.each_with_index { |child, index| check_references(root, child, "#{at}/#{index}", problems) }
    end
  end

  private def self.resolve(root : JSON::Any, ref : String) : JSON::Any?
    return unless ref.starts_with?("#/")
    ref.lchop("#/").split('/').reduce(root) do |node, token|
      token = token.gsub("~1", "/").gsub("~0", "~")
      child = node.as_h?.try(&.[token]?) || node.as_a?.try { |array| token.to_i?.try { |index| array[index]? } }
      return unless child
      child
    end
  end

  private def self.check_component_names(components : JSON::Any?, problems : Array(String)) : Nil
    return unless components
    components.as_h.each do |section, entries|
      entries.as_h.each_key do |name|
        problems << "components.#{section}.#{name} is not a valid component name" unless name.matches?(/\A[a-zA-Z0-9._-]+\z/)
      end
    end
  end

  # A "type" keyword holds a JSON Schema type name or a list of them.
  private def self.check_types(node : JSON::Any, at : String, problems : Array(String)) : Nil
    if hash = node.as_h?
      if type = hash["type"]?
        names = type.as_a?.try(&.map(&.as_s?)) || [type.as_s?]
        problems << "#{at}: #{type} is not a JSON Schema type" unless names.all? { |name| name && TYPES.includes?(name) }
      end
      hash.each { |key, child| check_types(child, "#{at}/#{key}", problems) unless key == "properties" || key == "example" }
      hash["properties"]?.try(&.as_h?).try &.each { |key, child| check_types(child, "#{at}/properties/#{key}", problems) }
    elsif array = node.as_a?
      array.each_with_index { |child, index| check_types(child, "#{at}/#{index}", problems) }
    end
  end
end
