require "uri"
require "random/secure"

module Azu
  # The one place an application's environment is read: `.env` files, typed accessors and secrets.
  #
  # Standalone and standard-library only (`require "azu/env"` works without the rest of Azu), and nothing
  # happens when it is required: files are read only by an explicit `Env.load` / `Env.load_all`.
  #
  # ```
  # require "azu/env"
  # Azu::Env.load_all # before `require "azu"`: Azu::CONFIG reads PORT, HOST and CRYSTAL_ENV when it is created
  # require "azu"
  #
  # Azu::Env.required("DATABASE_URL", "CSRF_SECRET") # one error naming every missing variable
  # port = Azu::Env.int("PORT", 4000)
  # secret = Azu::Env.secret("CSRF_SECRET") # random outside production, an error in production
  # ```
  #
  # Precedence, highest first: the process environment, `.env.local`, `.env.<CRYSTAL_ENV>`, `.env`. A file never
  # overrides a variable the process already has, so a container that injects real values is unaffected by a
  # `.env` left in the image. Files are data: no interpolation, no command substitution, nothing is executed.
  #
  # Errors name the variable (or file and line) and never print a value.
  module Env
    class Error < Exception
    end

    # One or more variables are unset or blank; `names` lists every one of them.
    class MissingError < Error
      getter names : Array(String)

      def initialize(@names : Array(String))
        super(@names.size == 1 ? "#{@names.first} is not set" : "#{@names.join(", ")} are not set")
      end

      def initialize(name : String)
        initialize([name])
      end
    end

    # A variable is set but is not a boolean, integer or URL. The value is not part of the message.
    class InvalidError < Error
      getter name : String

      def initialize(@name : String, expected : String)
        super("#{@name} is not #{expected}")
      end
    end

    # A `.env` file is malformed. Names the origin and line, never the text.
    class ParseError < Error
      getter origin : String
      getter line : Int32

      def initialize(@origin : String, @line : Int32, problem : String)
        super("#{@origin}:#{@line}: #{problem}")
      end
    end

    REDACTED    = "[FILTERED]"
    SENSITIVE   = /SECRET|PASSWORD|PASSWD|TOKEN|PRIVATE|CREDENTIAL|(\A|_)KEY\z|(\A|_)KEY_|COOKIE/i
    URL_SECRET  = %r{\A([a-z][a-z0-9+.\-]*://[^:/@\s]*):[^@/\s]*@}i
    TRUE_WORDS  = %w[1 true yes on t y]
    FALSE_WORDS = %w[0 false no off f n]

    @@generated_secrets = {} of String => String

    # The environment the process runs in: `CRYSTAL_ENV` lowercased, `development` when unset or blank.
    def self.environment : String
      ENV["CRYSTAL_ENV"]?.presence.try(&.strip.downcase) || "development"
    end

    def self.production? : Bool
      environment == "production"
    end

    # Parses the text of a `.env` file. Does not touch the process environment.
    #
    # Grammar: `KEY=VALUE` per line; blank lines and `#` comments are skipped; an `export ` prefix is allowed;
    # a bare value ends at a `#` that follows whitespace; `'...'` is literal; `"..."` understands `\n \t \r \" \\`
    # (any other backslash stays as written); quoted values may span lines; `$` is an ordinary character.
    def self.parse(source : String, origin : String = "(string)") : Hash(String, String)
      Parser.new(source, origin).parse
    end

    # Reads one `.env` file into the process environment and returns the names it set. A missing file is not an
    # error. Variables the process already has (even empty ones) are kept unless `override` is true.
    def self.load(path : String = ".env", override : Bool = false) : Array(String)
      return [] of String unless File.file?(path)

      apply(parse(File.read(path), path), override)
    end

    # Loads `.env`, `.env.<CRYSTAL_ENV>` and `.env.local` from `dir` with the precedence documented on `Env`.
    # `CRYSTAL_ENV` itself may come from the files; the process value wins.
    def self.load_all(dir : String = ".", override : Bool = false) : Array(String)
      base = read(File.join(dir, ".env"))
      local = read(File.join(dir, ".env.local"))
      merged = base
      env = ENV["CRYSTAL_ENV"]?.presence || local["CRYSTAL_ENV"]? || base["CRYSTAL_ENV"]? || "development"
      env = env.strip.downcase
      merged = merged.merge(read(File.join(dir, ".env.#{env}"))) if env.matches?(/\A[a-z0-9_\-]+\z/)
      apply(merged.merge(local), override)
    end

    # The value of `name`; blank counts as unset.
    def self.fetch?(name : String) : String?
      ENV[name]?.presence
    end

    def self.fetch(name : String) : String
      fetch?(name) || raise MissingError.new(name)
    end

    def self.fetch(name : String, default : String) : String
      fetch?(name) || default
    end

    def self.bool(name : String) : Bool
      to_bool(name, fetch(name))
    end

    def self.bool(name : String, default : Bool) : Bool
      value = fetch?(name)
      value ? to_bool(name, value) : default
    end

    def self.int(name : String) : Int32
      to_int(name, fetch(name))
    end

    def self.int(name : String, default : Int32) : Int32
      value = fetch?(name)
      value ? to_int(name, value) : default
    end

    def self.url(name : String) : URI
      to_url(name, fetch(name))
    end

    def self.url(name : String, default : String) : URI
      to_url(name, fetch?(name) || default)
    end

    # Raises one `MissingError` listing every unset or blank name; use it for boot checks.
    def self.required(*names : String) : Nil
      missing = names.to_a.reject { |name| fetch?(name) }
      raise MissingError.new(missing) unless missing.empty?
    end

    # The secret `name`: its value when set; a random value outside production (the same one for the life of the
    # process, so two readers of one name agree); an error in production. Set it in the environment or `.env`.
    def self.secret(name : String, production : Bool = production?) : String
      fetch?(name) || begin
        raise MissingError.new(name) if production
        @@generated_secrets[name] ||= Random::Secure.hex(32)
      end
    end

    # Forgets the random fallbacks `secret` handed out; for specs.
    def self.reset_generated_secrets! : Nil
      @@generated_secrets.clear
    end

    # `value` for logging: `[FILTERED]` for names that look like secrets, the password of a URL hidden.
    def self.redact(name : String, value : String) : String
      return REDACTED if name.matches?(SENSITIVE)

      value.sub(URL_SECRET, "\\1:#{REDACTED}@")
    end

    def self.redacted(vars : Hash(String, String)) : Hash(String, String)
      vars.to_h { |name, value| {name, redact(name, value)} }
    end

    private def self.read(path : String) : Hash(String, String)
      File.file?(path) ? parse(File.read(path), path) : {} of String => String
    end

    private def self.apply(vars : Hash(String, String), override : Bool) : Array(String)
      applied = [] of String
      vars.each do |name, value|
        next if !override && ENV.has_key?(name)

        ENV[name] = value
        applied << name
      end
      applied
    end

    private def self.to_bool(name : String, value : String) : Bool
      word = value.strip.downcase
      return true if TRUE_WORDS.includes?(word)
      return false if FALSE_WORDS.includes?(word)

      raise InvalidError.new(name, "a boolean (true/false, 1/0, yes/no, on/off)")
    end

    private def self.to_int(name : String, value : String) : Int32
      value.strip.to_i? || raise InvalidError.new(name, "an integer")
    end

    private def self.to_url(name : String, value : String) : URI
      uri = URI.parse(value.strip)
      raise InvalidError.new(name, "a URL") if uri.scheme.try(&.empty?) != false || value.matches?(/\s/)
      uri
    rescue URI::Error
      raise InvalidError.new(name, "a URL")
    end

    # Scans a `.env` text. One pass over the characters, so multi-line quoted values cost nothing extra.
    private class Parser
      def initialize(source : String, @origin : String)
        @chars = source.lchop('﻿').gsub("\r\n", "\n").chars
        @pos = 0
        @line = 1
      end

      def parse : Hash(String, String)
        vars = {} of String => String
        until eof?
          parse_line(vars)
        end
        vars
      end

      private def parse_line(vars : Hash(String, String)) : Nil
        skip_blanks
        case peek
        when nil
        when '\n' then advance
        when '#'  then skip_comment
        else
          name = read_name
          expect_equals
          vars[name] = read_value
        end
      end

      private def read_name : String
        skip_export
        start = @pos
        while (char = peek) && (char.ascii_alphanumeric? || char == '_')
          advance
        end
        name = @chars[start...@pos].join
        fail "invalid variable name" if name.empty? || name[0].ascii_number?
        name
      end

      # `export FOO=1`, but not a variable that is itself called export.
      private def skip_export : Nil
        return unless @chars[@pos, 6]? == ['e', 'x', 'p', 'o', 'r', 't'] && {' ', '\t'}.includes?(@chars[@pos + 6]?)

        @pos += 6
        skip_blanks
      end

      private def expect_equals : Nil
        skip_blanks
        fail "expected KEY=VALUE" unless peek == '='
        advance
        skip_blanks
      end

      private def read_value : String
        value = case peek
                when '"'  then read_double_quoted
                when '\'' then read_single_quoted
                else           return read_bare
                end
        finish_line
        value
      end

      private def read_bare : String
        start = @pos
        previous = ' '
        while (char = peek) && char != '\n'
          break if char == '#' && previous.whitespace?
          previous = char
          advance
        end
        text = @chars[start...@pos].join.rstrip
        skip_comment if peek == '#'
        reject_nul(text)
      end

      private def read_single_quoted : String
        opened = @line
        advance
        start = @pos
        until peek == '\''
          unterminated(opened) if eof?
          advance
        end
        text = @chars[start...@pos].join
        advance
        reject_nul(text)
      end

      private def read_double_quoted : String
        opened = @line
        advance
        text = String.build do |io|
          loop do
            unterminated(opened) unless char = peek
            advance
            break if char == '"'
            char == '\\' ? io << unescape : io << char
          end
        end
        reject_nul(text)
      end

      private def unescape : String
        unterminated(@line) unless char = peek
        advance
        case char
        when 'n'  then "\n"
        when 't'  then "\t"
        when 'r'  then "\r"
        when '"'  then "\""
        when '\\' then "\\"
        else           "\\#{char}"
        end
      end

      # After a quoted value only blanks and a comment may follow on the line.
      private def finish_line : Nil
        skip_blanks
        case peek
        when nil
        when '\n' then advance
        when '#'  then skip_comment
        else           fail "unexpected text after a quoted value"
        end
      end

      private def skip_blanks : Nil
        while (char = peek) && (char == ' ' || char == '\t' || char == '\r')
          advance
        end
      end

      private def skip_comment : Nil
        while (char = peek) && char != '\n'
          advance
        end
        advance if peek == '\n'
      end

      private def reject_nul(text : String) : String
        fail "a value contains a NUL byte" if text.includes?('\0')
        text
      end

      private def unterminated(line : Int32) : NoReturn
        raise ParseError.new(@origin, line, "unterminated quote")
      end

      private def fail(problem : String) : NoReturn
        raise ParseError.new(@origin, @line, problem)
      end

      private def peek : Char?
        @chars[@pos]?
      end

      private def eof? : Bool
        @pos >= @chars.size
      end

      private def advance : Nil
        @line += 1 if @chars[@pos]? == '\n'
        @pos += 1
      end
    end
  end
end
