module Azu
  # Adds fields to the `Vary` header of a response, as whole tokens.
  # :nodoc:
  module Vary
    # Joins the fields the header lacks (compared whole and case-insensitively) to its value, written as one
    # comma list. A `Vary: *` is left alone, as is a header that already names every field.
    def self.add(headers : HTTP::Headers, *fields : String) : Nil
      add(headers, fields.to_a)
    end

    def self.add(headers : HTTP::Headers, fields : Array(String)) : Nil
      present = tokens(headers)
      return if present.includes?("*")

      missing = fields.reject { |field| present.includes?(field.downcase) }.uniq(&.downcase)
      return if missing.empty?

      existing = headers.get?("Vary") || [] of String
      headers["Vary"] = (existing.map(&.strip).reject(&.empty?) + missing).join(",")
    end

    private def self.tokens(headers : HTTP::Headers) : Array(String)
      (headers.get?("Vary") || [] of String).flat_map(&.split(',')).map { |token| token.strip.downcase }.reject(&.empty?)
    end
  end
end
