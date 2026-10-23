require "http"
require "json"
require "html"
require "../params"
require "../routes"
require "../session"
require "../templates"
require "./csrf"
require "./endpoint_helpers"
require "./endpoint_routing"
require "../helpers/registry"
require "../helpers/util"

module Azu
  # `Azu::Endpoint` is the base class of every HTTP endpoint: one small class per route,
  # with the route, the typed parameters and the action in one place.
  #
  # ```
  # class CreateUser < Azu::Endpoint
  #   post "/users"
  #
  #   params do
  #     param :email, String, required: true, format: :email
  #     param :name, String, min_length: 2
  #   end
  #
  #   def call
  #     user = User.create!(**params.to_named_tuple)
  #     render :created, user
  #   end
  # end
  # ```
  #
  # What you get for free:
  #
  # * **Routing**: `get`, `post`, `put`, `patch`, `delete`, ... register the route when the
  #   class is defined. `get "/users/:id", as: :user` also names it (see `Azu::Routes`).
  # * **Typed, validated params**: `params do ... end` builds a struct from the path, query,
  #   form or JSON body and validates it before `call` runs. Failures answer `422` with the
  #   offending fields (`Azu::Response::ValidationError`).
  # * **Rendering**: `render :created, user`, `render :unprocessable_entity, errors: {...}`,
  #   `render template: "users/show.jinja", user: user`, `head :no_content`,
  #   `redirect_to "/users", notice: "Saved"`. What `call` returns is rendered if it is an
  #   `Azu::Response`, a `String`, a `Hash`/`Array`/`NamedTuple` or `JSON::Serializable`
  #   and nothing was rendered explicitly.
  # * **Hooks**: `before_action`, `after_action` and `rescue_from`.
  # * **Session and flash**: `session[:user_id] = "1"`, `flash[:notice] = "Saved"`.
  # * **Caching**: `cache_for 5.minutes`.
  #
  # The typed `Azu::Action(Request, Response)` module remains available for the
  # contract-first style.
  abstract class Endpoint
    include HTTP::Handler
    include EndpointHelpers
    include Templates::Renderable

    # Shorthand so endpoints can write `rescue ex : ValidationError`.
    alias ValidationError = Azu::Response::ValidationError

    # Raised when an endpoint tries to render twice.
    class DoubleRenderError < Exception
      def initialize
        super("render/redirect_to/head was called more than once in the same request. " \
              "Return after the first one (e.g. `return render(:ok)`).")
      end
    end

    # Input of an endpoint that did not declare `params do ... end`; only the raw
    # path/query/form access of `Azu::Params` is available.
    struct NoInput
      include Azu::Request
    end

    # Built-in values for `param ..., format: :name`.
    FORMATS = {
      email:        /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/,
      url:          /\Ahttps?:\/\/[^\s\/$.?#][^\s]*\z/i,
      uuid:         /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
      slug:         /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      alpha:        /\A[[:alpha:]]+\z/,
      alphanumeric: /\A[[:alnum:]]+\z/,
      digits:       /\A\d+\z/,
      date:         /\A\d{4}-\d{2}-\d{2}\z/,
      ipv4:         /\A(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\z/,
    }

    # Symbolic status names accepted by `render`, `head` and `redirect_to`
    # (`:ok`, `:created`, `:unprocessable_entity`, ...), derived from `HTTP::Status`.
    STATUS_SYMBOLS = begin
      statuses = {} of Symbol => HTTP::Status
      {% for name in HTTP::Status.constants %}
        statuses[:{{name.stringify.downcase.id}}] = HTTP::Status::{{name}}
      {% end %}
      statuses
    end

    @context : HTTP::Server::Context? = nil
    @raw_params : Params(NoInput)? = nil
    @session : Session? = nil
    @rendered : Bool = false

    # The action. Write it without arguments or return type:
    #
    # ```
    # def call
    #   render :ok, {status: "up"}
    # end
    # ```
    abstract def call

    macro inherited
      define_endpoint_routes

      BEFORE_ACTIONS = [] of Nil
      AFTER_ACTIONS  = [] of Nil

      macro finished
        # :nodoc:
        def __run_before_actions : Nil
          super
          \{% for action in BEFORE_ACTIONS %}
            return if @rendered
            \{{action.id}}
          \{% end %}
        end

        # :nodoc:
        def __run_after_actions : Nil
          super
          \{% for action in AFTER_ACTIONS %}
            \{{action.id}}
          \{% end %}
        end
      end
    end

    # Declares the typed parameters of the endpoint.
    #
    # Values come from the path (`:id`), the query string, a form or a JSON body, and are
    # validated before `call`. Each `param` becomes a getter on `params`.
    #
    # ```
    # params do
    #   param :id, Int32 # from "/users/:id"
    #   param :email, String, required: true, format: :email
    #   param :name, String, min_length: 2, max_length: 50
    #   param :age, Int32, min: 18, max: 120
    #   param :role, String, default: "member", in: %w(member admin)
    #   param :tags, Array(String)
    # end
    # ```
    #
    # Options: `required`, `default`, `min_length`, `max_length` (String/Array), `min`,
    # `max` (numbers), `format` (`:email`, `:url`, `:uuid`, `:slug`, `:alpha`,
    # `:alphanumeric`, `:digits`, `:date`, `:ipv4` or a `Regex`), `in` (Array or Range)
    # and `message` (replaces the default error text of the field).
    #
    # `params` then returns the struct: `params.email`, `params.to_h`,
    # `params.to_named_tuple`. A required or defaulted param has a non-nil getter.
    macro params(&block)
      {% valid_options = %w(required default min_length max_length min max format in message) %}
      {% format_names = %w(email url uuid slug alpha alphanumeric digits date ipv4) %}
      {% numeric_types = %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128 Float32 Float64) %}
      {% body = block.body %}
      {% exprs = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% fields = [] of Nil %}

      {% if exprs.size == 0 %}
        {% block.raise "`params do ... end` is empty. Declare at least one `param :name, Type`." %}
      {% end %}

      {% for expr in exprs %}
        {% unless expr.is_a?(Call) && expr.name.stringify == "param" && !expr.receiver %}
          {% expr.raise "`params do ... end` only accepts `param` declarations, e.g. `param :email, String, required: true`. Got: #{expr}" %}
        {% end %}
        {% if expr.args.size != 2 %}
          {% expr.raise "`param` takes a name and a type, e.g. `param :email, String`. Got: #{expr}" %}
        {% end %}
        {% name = expr.args[0] %}
        {% type = expr.args[1] %}
        {% unless name.is_a?(SymbolLiteral) %}
          {% expr.raise "param name must be a Symbol like `:email`, got `#{name}`" %}
        {% end %}
        {% opts = {} of Nil => Nil %}
        {% if expr.named_args %}
          {% for arg in expr.named_args %}
            {% unless valid_options.includes?(arg.name.stringify) %}
              {% expr.raise "param :#{name.id}: unknown option `#{arg.name}`. Valid options: #{valid_options.join(", ").id}" %}
            {% end %}
            {% opts[arg.name.stringify] = arg.value %}
          {% end %}
        {% end %}
        {% if opts["min"] || opts["max"] %}
          {% unless numeric_types.includes?(type.stringify) %}
            {% expr.raise "param :#{name.id}: `min`/`max` apply to numeric types (Int32, Float64, ...), not #{type}. Use `min_length`/`max_length` for String or Array." %}
          {% end %}
        {% end %}
        {% if opts["min_length"] || opts["max_length"] %}
          {% if numeric_types.includes?(type.stringify) || type.stringify == "Bool" %}
            {% expr.raise "param :#{name.id}: `min_length`/`max_length` apply to String or Array, not #{type}. Use `min`/`max` for numbers." %}
          {% end %}
        {% end %}
        {% if opts["format"] && opts["format"].is_a?(SymbolLiteral) && !format_names.includes?(opts["format"].id.stringify) %}
          {% expr.raise "param :#{name.id}: unknown format `#{opts["format"]}`. Built-in formats: #{format_names.join(", ").id}. You can also pass a Regex." %}
        {% end %}
        {% fields << {name: name.id, type: type, opts: opts} %}
      {% end %}

      # Typed input of {{@type.name.id}}, built from the request and validated before `call`.
      struct Input
        include Azu::Request

        {% for field in fields %}
          @{{field[:name]}} : {{field[:type]}}? = nil
        {% end %}

        STRING_FIELDS = [{% for field in fields %}{% if field[:type].stringify == "String" %}{{field[:name].stringify}}, {% end %}{% end %}] of String

        def initialize(*, {% for field in fields %}{{field[:name]}} : {{field[:type]}}? = nil, {% end %})
          {% for field in fields %}
            @{{field[:name]}} = {{field[:name]}}
          {% end %}
        end

        {% for field in fields %}
          {% opts = field[:opts] %}
          {% if opts["required"] == true %}
            def {{field[:name]}} : {{field[:type]}}
              @{{field[:name]}}.not_nil!
            end
          {% elsif opts["default"] != nil %}
            def {{field[:name]}} : {{field[:type]}}
              value = @{{field[:name]}}
              value.nil? ? {{opts["default"]}} : value
            end
          {% else %}
            def {{field[:name]}} : {{field[:type]}}?
              @{{field[:name]}}
            end
          {% end %}
        {% end %}

        # All params as a `NamedTuple`.
        def to_named_tuple
          { {% for field in fields %}{{field[:name]}}: {{field[:name]}}, {% end %} }
        end

        # All params as a `Hash`.
        def to_h
          to_named_tuple.to_h
        end

        # Field name => messages; empty when the input is valid.
        def validation_errors : Hash(String, Array(String))
          found = {} of String => Array(String)
          {% for field in fields %}
            {% opts = field[:opts] %}
            {% fname = field[:name].stringify %}
            value_{{field[:name]}} = @{{field[:name]}}
            {% if opts["default"] != nil %}
              value_{{field[:name]}} = {{opts["default"]}} if value_{{field[:name]}}.nil?
            {% end %}
            {% if opts["required"] == true %}
              if value_{{field[:name]}}.nil? || (value_{{field[:name]}}.is_a?(String) && value_{{field[:name]}}.blank?)
                (found[{{fname}}] ||= [] of String) << {{opts["message"] || "is required"}}
              end
            {% end %}
            unless value_{{field[:name]}}.nil?
              {% if opts["min_length"] %}
                if value_{{field[:name]}}.size < {{opts["min_length"]}}
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "is too short (minimum is #{opts["min_length"]})"}}
                end
              {% end %}
              {% if opts["max_length"] %}
                if value_{{field[:name]}}.size > {{opts["max_length"]}}
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "is too long (maximum is #{opts["max_length"]})"}}
                end
              {% end %}
              {% if opts["min"] %}
                if value_{{field[:name]}} < {{opts["min"]}}
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "must be at least #{opts["min"]}"}}
                end
              {% end %}
              {% if opts["max"] %}
                if value_{{field[:name]}} > {{opts["max"]}}
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "must be at most #{opts["max"]}"}}
                end
              {% end %}
              {% if opts["format"] %}
                {% pattern = opts["format"].is_a?(SymbolLiteral) ? "Azu::Endpoint::FORMATS[#{opts["format"]}]".id : opts["format"] %}
                if value_{{field[:name]}}.is_a?(String) && !{{pattern}}.matches?(value_{{field[:name]}})
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "is invalid"}}
                end
              {% end %}
              {% if opts["in"] %}
                unless ({{opts["in"]}}).includes?(value_{{field[:name]}})
                  (found[{{fname}}] ||= [] of String) << {{opts["message"] || "is not included in the list"}}
                end
              {% end %}
            end
          {% end %}
          found
        end

        # Builds and validates the input of a request.
        #
        # Raises `Azu::Response::BadRequest` for unreadable input (400) and
        # `Azu::Response::ValidationError` for invalid values (422).
        def self.from_params(raw : Azu::Params(Azu::Endpoint::NoInput)) : self
          input = if body = raw.json
                    from_json(Azu::Endpoint.merge_json(body, raw, STRING_FIELDS))
                  else
                    from_www_form(raw.to_query)
                  end
          errors = input.validation_errors
          raise Azu::Response::ValidationError.new(errors) unless errors.empty?
          input
        rescue ex : JSON::ParseException | URI::SerializableError | Time::Format::Error | ArgumentError
          raise Azu::Response::BadRequest.new(ex.message.to_s)
        end
      end

      @input : Input? = nil

      # :nodoc:
      def __load_input : Nil
        @input = Input.from_params(raw_params)
      end

      # The validated, typed params of this request.
      def params : Input
        @input || raise "params accessed before the endpoint was called. Use `endpoint.call(context)`."
      end
    end

    # Runs *block* before `call`. Takes method names and/or a block. If a before action
    # renders or redirects, `call` is skipped, so it works as a guard.
    #
    # ```
    # before_action :authenticate!
    # before_action { header "X-Api-Version", "1" }
    #
    # private def authenticate!
    #   render :unauthorized, errors: ["Sign in first"] unless session[:user_id]?
    # end
    # ```
    macro before_action(*names, &block)
      {% for name in names %}
        {% BEFORE_ACTIONS << name.id.stringify %}
      {% end %}
      {% if block %}
        {% method_name = "__before_#{@type.name.stringify.gsub(/\W/, "_").id}_#{BEFORE_ACTIONS.size}" %}
        def {{method_name.id}} : Nil
          {{block.body}}
        end
        {% BEFORE_ACTIONS << method_name %}
      {% end %}
    end

    # Runs after `call` returned without raising. Same forms as `before_action`.
    macro after_action(*names, &block)
      {% for name in names %}
        {% AFTER_ACTIONS << name.id.stringify %}
      {% end %}
      {% if block %}
        {% method_name = "__after_#{@type.name.stringify.gsub(/\W/, "_").id}_#{AFTER_ACTIONS.size}" %}
        def {{method_name.id}} : Nil
          {{block.body}}
        end
        {% AFTER_ACTIONS << method_name %}
      {% end %}
    end

    # Maps an exception raised by the endpoint (or its hooks) to a response.
    # Unmapped exceptions keep propagating to `Azu::Handler::Rescuer`.
    #
    # ```
    # rescue_from(User::NotFound) { |ex| render :not_found, errors: [ex.message] }
    # rescue_from ValidationError, with: :invalid
    #
    # private def invalid(ex)
    #   render :unprocessable_entity, errors: ex.field_errors
    # end
    # ```
    macro rescue_from(klass, with handler = nil, &block)
      {% if block %}
        def handle_exception({{block.args[0] ? block.args[0].id : "ex".id}} : {{klass}}) : Nil
          {{block.body}}
        end
      {% elsif handler %}
        def handle_exception(ex : {{klass}}) : Nil
          {{handler.id}}(ex)
        end
      {% else %}
        {% raise "rescue_from needs a block or `with: :method_name`" %}
      {% end %}
    end

    # Caches successful `GET` responses in `Azu.cache` for *ttl*. The key defaults to the
    # request path and query; pass a block to compute your own (it runs per request).
    #
    # ```
    # cache_for 5.minutes
    # cache_for(1.hour) { "report:#{params.year}" }
    # ```
    macro cache_for(ttl, &block)
      # :nodoc:
      def __cache_ttl : Time::Span?
        {{ttl}}
      end

      {% if block %}
        # :nodoc:
        def __cache_key : String
          {{block.body}}
        end
      {% end %}
    end

    # :nodoc:
    def __run_before_actions : Nil
    end

    # :nodoc:
    def __run_after_actions : Nil
    end

    # :nodoc:
    def __load_input : Nil
    end

    # :nodoc:
    def __cache_ttl : Time::Span?
      nil
    end

    # :nodoc:
    def __cache_key : String
      "azu:endpoint:#{self.class.name}:#{context.request.resource}"
    end

    # :nodoc:
    def handle_exception(ex : Exception) : Nil
      raise ex
    end

    # :nodoc:
    def call(context : HTTP::Server::Context)
      @context = context
      @raw_params = nil
      @session = nil
      @rendered = false
      context.request.headers["X-Azu-Endpoint"] = self.class.name.split("::").last

      begin
        __load_input
        __run_before_actions
        __cached { __invoke } unless @rendered
      rescue ex
        handle_exception(ex)
      end

      @session.try(&.commit(context.request, context.response))
      context
    end

    # The raw `Azu::Params`: `raw_params["id"]`, `raw_params.query`, `raw_params.files`.
    # Use it for ad-hoc values you did not declare with `params do ... end`.
    def raw_params : Params(NoInput)
      @raw_params ||= Params(NoInput).new(context.request)
    end

    # Without a `params do ... end` block, `params` is the raw `Azu::Params`.
    def params : Params(NoInput)
      raw_params
    end

    # The raw HTTP context. Raises if the endpoint was not invoked via `call(context)`.
    def context : HTTP::Server::Context
      @context || raise "Endpoint context accessed before initialization. Ensure call(context) was invoked."
    end

    # The signed-cookie session (see `Azu::Session`).
    def session : Session
      @session ||= Session.load(context.request.cookies)
    end

    # One-request flash messages (see `Azu::Session::Flash`).
    def flash : Session::Flash
      session.flash
    end

    # The body of the request parsed as JSON.
    private def json : JSON::Any
      JSON.parse(raw_params.json || "null")
    end

    # Renders a response.
    #
    # ```
    # render :created, user                                  # 201, JSON body
    # render user                                            # 200, JSON body
    # render :ok, user, serializer: UserSerializer           # UserSerializer.new(user).to_json
    # render :unprocessable_entity, errors: {email: ["bad"]} # 422, {"errors": ...}
    # render template: "users/show.jinja", user: user        # 200, HTML from a template
    # render html: "<h1>Hello</h1>"                          # 200, HTML string
    # render :ok, "pong"                                     # text
    # render :ok, MyPage.new                                 # any Azu::Response
    # ```
    #
    # *status* is a Symbol such as `:created` or `:not_found`, an `HTTP::Status` or an Int.
    # An unknown Symbol raises with the list of valid names.
    private def render(status : Symbol | HTTP::Status | Int32, object = nil, *, serializer = nil, errors = nil, template : String? = nil, html : String? = nil, **locals) : Nil
      raise DoubleRenderError.new if @rendered
      code = status_for(status)
      context.response.status = code

      if html
        default_content_type "text/html; charset=utf-8"
        context.response << html
      elsif template
        default_content_type "text/html; charset=utf-8"
        context.response << view(template, locals)
      elsif !errors.nil?
        default_content_type "application/json; charset=utf-8"
        context.response << {errors: errors}.to_json
      elsif !object.nil?
        write_body serialize(object, serializer)
      end
      @rendered = true
    end

    private def render(object, *, serializer = nil, **locals) : Nil
      render(:ok, object, **locals, serializer: serializer)
    end

    private def render(*, template : String, **locals) : Nil
      render(:ok, **locals, template: template)
    end

    private def render(*, html : String) : Nil
      render(:ok, html: html)
    end

    # Sends only a status and headers.
    #
    # ```
    # head :no_content
    # ```
    private def head(status : Symbol | HTTP::Status | Int32 = :ok) : Nil
      raise DoubleRenderError.new if @rendered
      context.response.status = status_for(status)
      @rendered = true
    end

    # Redirects. Defaults to `302 Found`; use `:see_other` after a POST/DELETE and
    # `:moved_permanently` for permanent moves. `notice:` and `alert:` become flash
    # messages for the next request.
    #
    # ```
    # redirect_to "/users", notice: "Saved"
    # redirect_to url_for(:user, id: 1), :see_other
    # ```
    private def redirect_to(location : String, status : Symbol | HTTP::Status | Int32 = :found, *, notice : String? = nil, alert : String? = nil) : Nil
      raise DoubleRenderError.new if @rendered
      flash[:notice] = notice if notice
      flash[:alert] = alert if alert
      context.response.status = status_for(status)
      context.response.headers["Location"] = location
      @rendered = true
    end

    # Sends bytes with a content type (and optionally as an attachment).
    #
    # ```
    # send_data csv, type: "text/csv", filename: "users.csv"
    # ```
    private def send_data(data : String | Bytes, type : String = "application/octet-stream", filename : String? = nil, disposition : String = "attachment") : Nil
      raise DoubleRenderError.new if @rendered
      context.response.content_type = type
      if filename
        context.response.headers["Content-Disposition"] = %(#{disposition}; filename="#{filename.gsub('"', "")}")
      end
      context.response.write(data.is_a?(String) ? data.to_slice : data)
      @rendered = true
    end

    # Streams a file from disk. The content type is guessed from the extension.
    #
    # ```
    # send_file "reports/2026.pdf"
    # send_file path, filename: "report.pdf", disposition: "inline"
    # ```
    private def send_file(path : String, type : String? = nil, filename : String? = nil, disposition : String = "attachment") : Nil
      raise DoubleRenderError.new if @rendered
      raise File::NotFoundError.new("send_file: no such file", file: path) unless File.file?(path)
      context.response.content_type = type || MIME.from_filename?(path) || "application/octet-stream"
      name = filename || File.basename(path)
      context.response.headers["Content-Disposition"] = %(#{disposition}; filename="#{name.gsub('"', "")}")
      File.open(path) { |file| IO.copy(file, context.response) }
      @rendered = true
    end

    # Expands a named route (`get "/users/:id", as: :user`).
    #
    # ```
    # url_for(:user, id: 42) # => "/users/42"
    # ```
    private def url_for(name : Symbol, **params) : String
      Routes.path(name, **params)
    end

    private def status_for(status : HTTP::Status) : HTTP::Status
      status
    end

    private def status_for(status : Int32) : HTTP::Status
      HTTP::Status.new(status)
    end

    private def status_for(status : Symbol) : HTTP::Status
      STATUS_SYMBOLS[status]? || raise ArgumentError.new(
        "Unknown status :#{status}. Common names: :ok, :created, :accepted, :no_content, :found, " \
        ":see_other, :bad_request, :unauthorized, :forbidden, :not_found, :unprocessable_entity, " \
        ":too_many_requests, :internal_server_error."
      )
    end

    private def default_content_type(type : String) : Nil
      context.response.content_type = type unless context.response.headers.has_key?("Content-Type")
    end

    private def write_body(body : {String, String?}) : Nil
      if type = body[1]
        default_content_type type
      end
      context.response << body[0]
    end

    private def serialize(object, serializer : Nil) : {String, String?}
      encode(object)
    end

    private def serialize(object, serializer) : {String, String?}
      encode(serializer.new(object))
    end

    private def encode(object : Azu::Response) : {String, String?}
      {object.render.to_s, nil}
    end

    private def encode(object : String) : {String, String?}
      {object, "text/plain; charset=utf-8"}
    end

    private def encode(object) : {String, String?}
      {object.to_json, "application/json; charset=utf-8"}
    end

    # Runs `call` and renders what it returned, unless it rendered by itself.
    private def __invoke : Nil
      result = call
      __write_result(result) unless @rendered
      __run_after_actions
    end

    private def __write_result(result : Azu::Response) : Nil
      context.response << result.render
      @rendered = true
    end

    private def __write_result(result : String) : Nil
      render(:ok, result)
    end

    private def __write_result(result : Hash | Array | NamedTuple | JSON::Serializable) : Nil
      render(:ok, result)
    end

    private def __write_result(result) : Nil
    end

    private def __cached(&) : Nil
      ttl = __cache_ttl
      unless ttl && context.request.method == "GET"
        yield
        return
      end

      key = __cache_key
      if cached = Azu.cache.get(key)
        payload = JSON.parse(cached)
        context.response.status_code = payload["status"].as_i
        payload["type"].as_s?.try { |type| context.response.content_type = type }
        context.response.headers["X-Azu-Cache"] = "HIT"
        context.response << payload["body"].as_s
        @rendered = true
        return
      end

      buffer = IO::Memory.new
      original = context.response.output
      context.response.output = IO::MultiWriter.new(original, buffer)
      begin
        yield
      ensure
        context.response.output = original
      end

      if context.response.status_code == 200
        Azu.cache.set(key, {status: 200, type: context.response.headers["Content-Type"]?, body: buffer.to_s}.to_json, ttl)
      end
    end

    # Merges path and query params into a JSON body so declared params can come from any
    # source: path params win over the body, the body wins over the query string.
    # Values for String fields stay strings; everything else is parsed as JSON.
    def self.merge_json(body : String, raw : Params(NoInput), string_fields : Array(String)) : String
      parsed = JSON.parse(body).as_h?
      return body unless parsed

      merged = Hash(String, JSON::Any).new
      raw.query.to_h.each { |key, value| merged[key] = coerce(key, value, string_fields) }
      parsed.each { |key, value| merged[key] = value }
      raw.path.each { |key, value| merged[key] = coerce(key, value, string_fields) }
      merged.to_json
    end

    private def self.coerce(key : String, value : String, string_fields : Array(String)) : JSON::Any
      return JSON::Any.new(value) if string_fields.includes?(key)
      JSON.parse(value)
    rescue JSON::ParseException
      JSON::Any.new(value)
    end
  end
end
