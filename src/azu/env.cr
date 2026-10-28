require "uri"
require "log"
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
  # Errors name the variable (or file and line) and never print a value. One bad line fails the whole file (it sets
  # nothing), and a file larger than 1 MB is refused.
  #
  # Trust: an application loads its own `.env`, but a variable that changes how processes are started or how the
  # toolchain, the resolver, TLS or proxies behave (`LD_*`, `DYLD_*`, `PATH`, `SHELL`, `HOME`, `CRYSTAL_*` except
  # `CRYSTAL_ENV` and `CRYSTAL_LOG_*`, `GIT_*`, `SHARDS_*`, `DOCKER_*`, `CC`, `*FLAGS`, `*_PROXY`, `SSL_CERT_*`,
  # `LANG`, `LC_*`, `TZ`, ...; see `UNSAFE_NAME`) is skipped with a warning naming it, so a copied file cannot hijack
  # the process or the tools it spawns. Pass `unsafe: true` to load them anyway.
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

    REDACTED = "[FILTERED]"
    # Names (environment variables, header names, query parameter names; `-` counts like `_`) that hold a credential.
    SENSITIVE = /SECRET|PASSWORD|PASSWD|PASSPHRASE|PASSCODE|TOKEN|CSRF|PRIVATE|CREDENTIAL|KEY\z|[_-]KEY[_-]|\AKEY[_-]|COOKIE|AUTH|DSN|SALT|SIGNING|SIGNATURE|JWT|(\A|[_-])SESSION([_-](ID|DATA|URL|STORE|COOKIE|STRING)|\z)|CONNECTION[_-]?STRING|[_-]PWD([_-]|\z)|\APWD[_-]|(\A|[_-])(PASS|SID|OTP|PIN|CVV|CVC|SSN|CARD)([_-]|\z)/i
    # `scheme://user:password@host` anywhere in a value.
    URL_SECRET = %r{([a-z][a-z0-9+.\-]*://[^:/@\s]*):(?!\d+(?:[/?#]|\z))[^\s?#]*@}i
    # `?name=value` / `&name=value` anywhere in a value.
    QUERY_PAIR    = /([?&;])([^=&#\s]+)=([^&#\s]*)/
    MAX_FILE_SIZE = 1_048_576
    # Names that change how processes start, where they look for code, libraries, certificates or proxies, or how the
    # toolchain behaves; `.env` files may not set them by default. Matched case-insensitively. This is the same set as
    # `AzuCLI::DotEnv::UNSAFE_NAME` in the azu CLI (minus the CLI's own `AZU_OUTPUT_PATH` / `AZU_TEMPLATES_PATH`), so the
    # CLI and the app agree on what a file may set. `CRYSTAL_ENV` and `CRYSTAL_LOG_*` are the only `CRYSTAL_*` names allowed.
    # BASH_FUNC_*%% (exported shell functions) is unreachable: the parser rejects a name with `%`.
    UNSAFE_NAME = /\A(?:
      LD_.*|DYLD_.*|SHARDS_.*|GIT_.*|CRYSTAL_(?!ENV\z|LOG_).*|DOCKER_.*|COMPOSE_.*|SSH_.*|PKG_CONFIG(?:_.*)?|PYTHON.*|PERL5.*|RUBY.*|XDG_.*
      |PATH|SHELL|IFS|BASH_ENV|ENV|HOME|TMPDIR|SHELLOPTS|PS4|PROMPT_COMMAND|CDPATH|GLOBIGNORE
      |CC|CXX|CPP|.*FLAGS|LDLIBS|LIBS|AR|AS|LD|COMPILER_PATH|GCC_EXEC_PREFIX|OBJC_INCLUDE_PATH|SDKROOT|DEVELOPER_DIR|CPATH|C_INCLUDE_PATH|CPLUS_INCLUDE_PATH|LIBRARY_PATH
      |GLIBC_TUNABLES|GCONV_PATH|LOCPATH|NLSPATH|SSL_CERT_FILE|SSL_CERT_DIR
      |HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|FTP_PROXY|EDITOR|VISUAL|PAGER|BROWSER|NODE_OPTIONS
      |OPENSSL_CONF|OPENSSL_MODULES|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|CURL_HOME|WGETRC|HOSTALIASES|LOCALDOMAIN|RES_OPTIONS
      |PERLLIB|PERLIO|RUBYOPT|LUA_PATH|LUA_CPATH|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|CLASSPATH|GEM_HOME|GEM_PATH
      |BUNDLE_.*|NPM_CONFIG_.*|HOMEBREW_.*|GOPROXY|GOFLAGS|CARGO_.*|RUSTC_WRAPPER|MAKEFLAGS
      |TERMINFO|TERMINFO_DIRS|TERMCAP|MANPATH|LANG|LANGUAGE|LC_.*|LOCALE_ARCHIVE|TZ|TZDIR|MALLOC_.*|ARGV0|_
      |USER|LOGNAME|PWD|OLDPWD|USERPROFILE
    )\z/ix
    TRUE_WORDS  = %w[1 true yes on t y]
    FALSE_WORDS = %w[0 false no off f n]

    @@generated_secrets = {} of String => String
    @@strict_environments : Array(String)? = nil

    # True for a variable name a `.env` file may not set unless loaded with `unsafe: true`.
    def self.unsafe_name?(name : String) : Bool
      name.matches?(UNSAFE_NAME)
    end

    # Environments in which `secret` raises instead of falling back to a random value. `production` by default;
    # `AZU_STRICT_ENVS=production,staging` or `Env.strict_environments = [...]` widens it.
    def self.strict_environments : Array(String)
      @@strict_environments || (ENV["AZU_STRICT_ENVS"]?.presence.try(&.split(',').map(&.strip.downcase).reject(&.empty?)) || ["production"])
    end

    # `nil` goes back to the default (`AZU_STRICT_ENVS`, then `production`).
    def self.strict_environments=(names : Array(String)?) : Array(String)?
      @@strict_environments = names.try(&.map(&.downcase))
    end

    def self.strict? : Bool
      strict_environments.includes?(environment)
    end

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
    def self.load(path : String = ".env", override : Bool = false, unsafe : Bool = false) : Array(String)
      return [] of String unless File.file?(path)

      apply(read(path), override, unsafe)
    end

    # Loads `.env`, `.env.<CRYSTAL_ENV>` and `.env.local` from `dir` with the precedence documented on `Env`.
    # `CRYSTAL_ENV` itself may come from the files; the process value wins.
    def self.load_all(dir : String = ".", override : Bool = false, unsafe : Bool = false) : Array(String)
      base = read(File.join(dir, ".env"))
      local = read(File.join(dir, ".env.local"))
      merged = base
      env = ENV["CRYSTAL_ENV"]?.presence || local["CRYSTAL_ENV"]? || base["CRYSTAL_ENV"]? || "development"
      env = env.strip.downcase
      merged = merged.merge(read(File.join(dir, ".env.#{env}"))) if env.matches?(/\A[a-z0-9_\-]+\z/)
      apply(merged.merge(local), override, unsafe)
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
    #
    # The random fallback is per process: several processes (or a restart) disagree on it, which breaks signed
    # cookies and tokens, so it logs one warning per name. Set the variable in `.env` for development.
    # `production` defaults to whether the environment is in `strict_environments`.
    def self.secret(name : String, production : Bool = strict?) : String
      fetch?(name) || begin
        raise MissingError.new(name) if production
        @@generated_secrets[name] ||= generate_secret(name)
      end
    end

    private def self.generate_secret(name : String) : String
      Log.for("azu.env").warn { "#{name} is not set: using a random value for this process only (set it in the environment or .env)" }
      Random::Secure.hex(32)
    end

    # Forgets the random fallbacks `secret` handed out; for specs.
    def self.reset_generated_secrets! : Nil
      @@generated_secrets.clear
    end

    # `value` for logging: `[FILTERED]` for names that look like secrets, the password of a URL hidden.
    def self.redact(name : String, value : String) : String
      return REDACTED if name.matches?(SENSITIVE)

      redact_url(value)
    end

    # A value that holds URLs (a referer, a request target, a connection string): the password of
    # `scheme://user:password@host` and the value of a credential-looking query parameter (`?token=...`) are replaced,
    # wherever they are in the text.
    def self.redact_url(value : String) : String
      value.gsub(URL_SECRET, "\\1:#{REDACTED}@").gsub(QUERY_PAIR) do |pair, match|
        match[2].matches?(SENSITIVE) ? "#{match[1]}#{match[2]}=#{REDACTED}" : pair
      end
    end

    def self.redacted(vars : Hash(String, String)) : Hash(String, String)
      vars.to_h { |name, value| {name, redact(name, value)} }
    end

    private def self.read(path : String) : Hash(String, String)
      return {} of String => String unless File.file?(path)
      raise ParseError.new(path, 1, "file is larger than 1 MB") if File.size(path) > MAX_FILE_SIZE

      parse(File.read(path), path)
    end

    # A blank CRYSTAL_ENV counts as unset, as `environment` does, so the file that picked `.env.<env>` can set it.
    private def self.in_process?(name : String) : Bool
      name == "CRYSTAL_ENV" ? !ENV[name]?.presence.nil? : ENV.has_key?(name)
    end

    private def self.apply(vars : Hash(String, String), override : Bool, unsafe : Bool) : Array(String)
      applied = [] of String
      vars.each do |name, value|
        next if !unsafe && skip_unsafe(name, override)
        next if !override && in_process?(name)

        ENV[name] = value
        applied << name
      end
      applied
    end

    # A denied name is skipped. It warns (logger `azu.env`, level warn, so it is invisible until logging is configured)
    # unless the real environment already has the name and the file could not override it anyway.
    private def self.skip_unsafe(name : String, override : Bool) : Bool
      return false unless unsafe_name?(name)

      unless !override && in_process?(name)
        Log.for("azu.env").warn { "ignoring #{name} from a .env file: it changes how the process, its tools, TLS or locale behave (set it in the real environment, or load with unsafe: true)" }
      end
      true
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
