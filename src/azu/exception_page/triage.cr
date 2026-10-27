require "socket"
require "./registry"

module Azu
  class ExceptionPage
    # The built-in likely causes: what an exception of a well-known class usually means in an Azu app, and where to
    # look. Each names the place in the app (`report.location`) and never prints a configuration value.
    module Triage
      extend self

      def where(report : Report) : String
        report.location.try { |frame| " at #{frame.location}" } || ""
      end

      def env_state(name : String) : String
        ENV[name]?.try { |value| value.empty? ? "#{name} is set but empty" : "#{name} is set" } || "#{name} is not set"
      end
    end

    hint(NilAssertionError) do |_error, report|
      Hint.new("A value was nil where the code assumed it was not",
        "`.not_nil!` or `.as(T)`#{Triage.where(report)} met nil. Handle the missing case with `if value = ...` or " \
        "`try`, or make sure the record, parameter or header it reads exists.", Tone::Bad)
    end

    hint(KeyError) do |error, report|
      key = error.message.try(&.[/"([^"]+)"/, 1]?)
      Hint.new(key ? "The key \"#{key}\" is missing" : "A key the code needs is missing",
        "`[]`#{Triage.where(report)} raises when the key is absent. If it comes from the request, check the client " \
        "sends it (see the Request tab) or read it with `[]?` and answer 422.", Tone::Bad)
    end

    hint(IndexError) do |_error, report|
      Hint.new("An index is out of bounds",
        "A collection#{Triage.where(report)} is shorter than the code expects, often an empty query result. " \
        "Use `first?`, `[]?` or check `empty?` first.", Tone::Bad)
    end

    hint(DivisionByZeroError) do |_error, report|
      Hint.new("Division by zero", "A divisor#{Triage.where(report)} was zero: guard counts and totals before dividing.", Tone::Bad)
    end

    hint(Crinja::TemplateNotFoundError) do |_error, _report|
      paths = Azu.current_config.templates.path
      Hint.new("The template file was not found",
        "Azu looks for templates in #{paths.empty? ? "no directory" : paths.join(", ")} (`templates.path`). Check the " \
        "name passed to `render` / `view` and where the file is.", Tone::Bad)
    end

    hint(Crinja::Error) do |error, _report|
      next if error.is_a?(Crinja::TemplateNotFoundError)
      Hint.new("The template failed to render",
        "Crinja raised while rendering a template: check the variable or filter it names and that the data passed " \
        "to the page has it.", Tone::Bad)
    end

    hint(JSON::ParseException) do |_error, _report|
      Hint.new("The JSON is not valid",
        "A JSON document could not be parsed: when it is the request body, the client sent malformed JSON (check " \
        "`Content-Type` and the body); when it is a file or an API response, check what was read.", Tone::Warn)
    end

    hint(JSON::SerializableError) do |_error, _report|
      Hint.new("The JSON does not have the expected shape",
        "A JSON::Serializable type met a missing key or a value of another type: compare the document with the " \
        "properties of the type it is read into.", Tone::Warn)
    end

    hint(Socket::ConnectError) do |_error, _report|
      Hint.new("A service refused the connection",
        "A database, Redis or HTTP service is not running or not reachable at the configured address " \
        "(#{Triage.env_state("DATABASE_URL")}, #{Triage.env_state("REDIS_URL")}).", Tone::Bad)
    end

    hint(Socket::Addrinfo::Error) do |_error, _report|
      Hint.new("A host name could not be resolved",
        "DNS did not resolve a host the app connects to: check the host in the connection URL " \
        "(#{Triage.env_state("DATABASE_URL")}, #{Triage.env_state("REDIS_URL")}).", Tone::Bad)
    end

    hint(IO::TimeoutError) do |_error, _report|
      Hint.new("An I/O operation timed out",
        "A socket read or write took longer than its timeout: a slow service, a lock or a lost connection.", Tone::Warn)
    end

    hint(ArgumentError) do |_error, report|
      Hint.new("A method got an argument it does not accept",
        "An argument#{Triage.where(report)} is out of range or malformed, often a parse (`to_i`, `Time.parse`) of " \
        "request input: validate it in the request contract instead.", Tone::Warn)
    end

    hint(NotImplementedError) do |_error, report|
      Hint.new("This code path is not implemented", "Something#{Triage.where(report)} raises NotImplementedError: it is a stub.", Tone::Warn)
    end

    # Database drivers (crystal-db, pg, sqlite3, mysql) are not core dependencies: recognised by class name.
    hint(Exception) do |error, _report|
      name = error.class.name
      next unless name.starts_with?("DB::") || name.starts_with?("PQ::") || name.starts_with?("SQLite3::") || name.starts_with?("MySql::")
      if name.includes?("Connection") || (error.message || "").downcase.includes?("connect")
        Hint.new("The database is not reachable",
          "The driver could not get a connection (#{Triage.env_state("DATABASE_URL")}): is the server running, and " \
          "does the URL name the right host, port and database?", Tone::Bad)
      else
        Hint.new("The database rejected a statement",
          "The driver raised #{name}: the Signals tab lists the queries of this request when database " \
          "instrumentation is on.", Tone::Bad)
      end
    end

    hint(Response::ValidationError) do |error, _report|
      fields = error.field_errors.keys
      Hint.new("The request did not pass its contract",
        "Invalid fields: #{fields.empty? ? "none named" : fields.join(", ")}. The request contract's `validate` rules " \
        "refused it; a client sees a 422 with these messages.", Tone::Info)
    end

    hint(Response::Error) do |error, report|
      next if error.is_a?(Response::ValidationError) || report.status >= 500
      Hint.new("The client's request was refused (#{report.status} #{report.status_text})",
        "This is a 4xx: the request, not the server, is at fault. #{error.detail.presence || error.title}", Tone::Info)
    end

    # Where it was raised, when that is not the app's own code.
    hint(Exception) do |_error, report|
      next if report.frames.empty? || report.frames.any?(&.app?)
      first = report.frames.first
      next unless first.kind.shard? || first.kind.azu?
      origin = first.kind.azu? ? "Azu" : "the #{first.shard} shard"
      Hint.new("Raised inside #{origin}, with no frame from the app",
        "The backtrace never enters the app's code: look at what the app passed to #{origin} (configuration, " \
        "arguments, the request) rather than at the shard itself.", Tone::Info)
    end
  end
end
