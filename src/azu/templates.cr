require "crinja"
require "./templates/crinja_patches"
require "./helpers"

module Azu
  # Templates are used by Azu when rendering responses.
  #
  # Since many views render significant content, for example a
  # whole HTML file, it is common to put these files into a particular
  # directory, typically "src/templates".
  #
  # This module provides conveniences for reading all files from a particular
  # directory and embedding them into a single module. Imagine you have a directory with templates:
  #
  # Templates::Renderable will define a private function named `render(template : String, data)` with
  # one clause per file system template.
  #
  # ```
  # render(template : String, data)
  # ```
  class Templates
    @crinja : Crinja
    @loader : Crinja::Loader::ChoiceLoader?
    @template_mtimes : Hash(String, Time) = Hash(String, Time).new
    @template_mtimes_mutex : Mutex = Mutex.new
    @last_check : Time = Time.utc
    @check_interval : Time::Span = 1.second
    @hot_reload_enabled : Bool = false
    @helpers_revision : UInt64? = nil
    @builtin_crinja : Crinja?
    @preloaded : PreloadedLoader?
    @preload_lock : Mutex = Mutex.new
    @preload_count : Int32 = 0
    @preloaded_strict : Bool = false
    @helpers_lock : Mutex = Mutex.new

    # Azu's own error pages, compiled into the binary. They are the last place the loader looks, so an app that
    # runs from any working directory (or from a container that holds only the binary) always finds them, and a
    # template of the same name in the app's directories, or in `error_path`, takes precedence.
    BUILTIN = {
      "error.html"       => {{ read_file("#{__DIR__}/templates/error.html") }},
      "error_debug.html" => {{ read_file("#{__DIR__}/templates/error_debug.html") }},
    }

    # Serves `BUILTIN` with the template name as the file name: Crinja chooses autoescape from the file name, and a
    # source without one would render unescaped (the error pages print the request path).
    class BuiltinLoader < Crinja::Loader::HashLoader
      def get_source(env : Crinja, template : String) : {String, String?}
        source, _ = super
        {source, template}
      end
    end

    # :nodoc:
    # A template that does not parse. The message names the template and carries Crinja's line.
    class PreloadError < Crinja::Error
    end

    # :nodoc:
    # Its name in 0.5.113 to 0.5.132.
    CompileError = PreloadError

    # :nodoc:
    # How many times the templates were preloaded; for specs.
    getter preload_count

    # Template names (globs on the name relative to a template directory, e.g. `"vendor/**"` or `"swagger/*.html"`)
    # that are not preloaded at boot: a file below the template directories that is not a template (a vendored page
    # with `{{ }}` in it) would otherwise stop the boot. They are still found by the file loader when asked for.
    getter preload_ignore : Array(String) = [] of String

    def preload_ignore=(patterns : Array(String))
      @preload_lock.synchronize do
        @preload_ignore = patterns
        @preloaded = nil
        crinja.loader = @loader.not_nil!
      end
    end

    @[Deprecated("Use `preload_ignore`.")]
    def compile_ignore : Array(String)
      preload_ignore
    end

    @[Deprecated("Use `preload_ignore=`.")]
    def compile_ignore=(patterns : Array(String))
      self.preload_ignore = patterns
    end

    # :nodoc:
    # Every template found below the template directories, read and parsed once, as an immutable name => template
    # map. `Templates` publishes it with a single assignment, so a request only ever sees a complete map. Includes
    # and extends resolve through it too, because it is the Crinja environment's loader. A name that is not in the
    # map (a file added after boot, a path like `./a//b`, another extension) goes to the loader it wraps.
    class PreloadedLoader < Crinja::Loader
      getter templates : Hash(String, Crinja::Template)

      def initialize(@templates : Hash(String, Crinja::Template), @fallback : Crinja::Loader)
      end

      def get_source(env : Crinja, template : String) : {String, String?}
        @fallback.get_source(env, template)
      end

      def load(env, name)
        @templates[name]? || @fallback.load(env, name)
      end

      def list_templates : Iterable(String)
        @fallback.list_templates
      end
    end

    # :nodoc:
    # Crinja's in-memory template cache behind a lock. Renders run on several threads under preview_mt, and a template
    # the preloaded map does not hold (hot reload, other extensions, `preload_ignore`, files added after boot, the
    # built-in pages) is parsed and stored here by whichever render asks for it first.
    class SynchronizedCache < Crinja::TemplateCache
      @cache = Crinja::TemplateCache::InMemory.new
      @lock = Mutex.new

      def fetch(env, name, file_name, source, &)
        @lock.synchronize { @cache.fetch(env, name, file_name, source) { yield } }
      end
    end

    # :nodoc:
    # A render's variables as the scope of its Crinja context, taken over instead of copied (rendering with a hash,
    # Crinja copies it twice: `Crinja.variables`, then into the context's own scope).
    class Scope < Crinja::Context
      def initialize(parent : Crinja::Context, variables : Crinja::Variables, @request : Helpers::TemplateContext? = nil)
        super(parent)
        @scope = variables
      end

      # A request variable (`TemplateContext::VARIABLES`) the data does not set is computed when the template first
      # reads it, then kept. It shadows a global of the same name, as when `view` set them all before rendering.
      def [](key : String) : Crinja::Value
        if value = @scope[key]?
          value
        elsif (request = @request) && (value = request.template_var(key))
          @scope[key] = value
        elsif enclosing = parent
          enclosing[key]
        else
          undefined
        end
      end
    end

    getter crinja = Crinja.new
    getter path : Array(String)
    getter error_path : String

    module Renderable
      # Renders a template with optional data and HTTP context awareness.
      #
      # When called from an endpoint with access to HTTP context, this method
      # automatically injects useful variables like csrf_token, current_path,
      # flash messages, and more.
      #
      # ```
      # def call : MyResponse
      #   view("users/show.jinja", {"user" => user})
      # end
      # ```
      private def view(template : String = page_path, data = Hash(String, Crinja::Value).new)
        template_data = Hash(String, Crinja::Value).new
        data.to_h.each { |k, v| template_data[k.to_s] = Crinja::Value.new(v) }

        # The request's variables when a context is available, each computed when the template reads it
        request = nil
        {% if @type.has_method?(:context) %}
          if ctx = (context rescue nil)
            request = Helpers::TemplateContext.for_render(ctx)
          end
        {% end %}

        Azu.current_config.templates.render_variables(template, template_data, request)
      end

      # Renders a template with explicit context injection.
      #
      # Use this when you need to explicitly provide HTTP context,
      # such as from a custom handler or middleware.
      #
      # ```
      # view_with_context("email.jinja", context, {"subject" => "Hello"})
      # ```
      private def view_with_context(
        template : String,
        http_context : HTTP::Server::Context,
        data = Hash(String, Crinja::Value).new,
      )
        template_data = Hash(String, Crinja::Value).new
        data.to_h.each { |k, v| template_data[k.to_s] = Crinja::Value.new(v) }
        request = Helpers::TemplateContext.for_render(http_context)

        Azu.current_config.templates.render_variables(template, template_data, request)
      end

      def page_path
        "#{self.class.name.split("::").join("/").underscore.downcase}.jinja"
      end
    end

    # File extensions (also as the inner extension of `x.json.jinja`) of formats that are not HTML and are not
    # escaped: HTML escaping would corrupt them, and they need their own encoding (`| tojson` for JSON and
    # JavaScript). `xml`, `rss`, `atom`, `svg`, `html` and `htm` stay escaped. A single block opts out inside a
    # template: `{% autoescape false %}...{% endautoescape %}`.
    PLAIN_TEXT_EXTENSIONS = %w(txt text json js mjs css csv md markdown yml yaml sql sh)

    # The autoescape rule of the environment. Crinja decides per template from the file name, and only knows
    # `html`, `htm` and `xml`; a `.jinja` or `.j2` name (the framework's own default, see `Renderable#page_path`)
    # has no inner extension and would not be escaped. With `enabled` everything is escaped but plain text
    # (`.txt`, `.text`, `x.txt.jinja`), string templates included; `| safe` is the opt-out for a value.
    def self.autoescape_rule(enabled : Bool) : Crinja::Config::Autoescape
      return Crinja::Config::Autoescape.new unless enabled
      Crinja::Config::Autoescape.new(disabled_extensions: PLAIN_TEXT_EXTENSIONS, default_for_string: true, default: true)
    end

    def initialize(@path : Array(String), @error_path : String, hot_reload : Bool? = nil, @preload_ignore : Array(String) = [] of String, autoescape : Bool = true)
      @hot_reload_enabled = hot_reload.nil? ? development_environment? : hot_reload
      crinja.cache = SynchronizedCache.new
      self.autoescape = autoescape
      initialize_loader
    end

    # The keyword `compile_ignore:` of 0.5.113 to 0.5.132.
    @[Deprecated("Use `preload_ignore:`.")]
    def self.new(path : Array(String), error_path : String, hot_reload : Bool? = nil, *, compile_ignore : Array(String), autoescape : Bool = true)
      new(path, error_path, hot_reload, compile_ignore, autoescape)
    end

    # Whether `.jinja`, `.j2` and string templates are autoescaped like `.html` (default). Decided at render time,
    # so it applies to preloaded templates too.
    getter? autoescape : Bool = true

    def autoescape=(enabled : Bool)
      @autoescape = enabled
      crinja.config.autoescape = Templates.autoescape_rule(enabled)
    end

    def path=(path : String)
      @path << Path[path].expand.to_s
      reload_loader
    end

    def error_path=(path : String)
      @error_path = Path[path].expand.to_s
      reload_loader
    end

    # Azu's own error page `name`, ignoring every directory: what is rendered when an app's `error.html` is broken.
    def builtin(name : String) : Crinja::Template
      env = @@builtin_lock.synchronize { @builtin_crinja ||= Crinja.new(loader: BuiltinLoader.new(BUILTIN), cache: SynchronizedCache.new) }
      env.get_template(name)
    end

    # Renders `template` with `data` (nil, a Hash or a NamedTuple). Renders run concurrently: each fiber renders in
    # its own Crinja context (see templates/crinja_patches.cr). A render starts from the global context even inside
    # another one (a helper that renders a fragment), so it never sees the outer request's variables: helpers that
    # render fragments should call this, not `load(name).render(data)`.
    def render(template : String, data = nil) : String
      scope = Crinja::Context.new(crinja.global_context)
      scope.merge!(data) if data
      load(template).render(scope)
    end

    # :nodoc:
    # `render` for variables built for this one render (`view`): it takes `variables` over as the render's scope,
    # without a copy, and writes to it (a top-level `set`, the request variables the template reads from `request`).
    def render_variables(template : String, variables : Crinja::Variables, request : Helpers::TemplateContext? = nil) : String
      load(template).render(Scope.new(crinja.global_context, variables, request))
    end

    # With reload on (development) every call may re-read changed files, see `check_for_changes`. Without it the
    # templates are preloaded: each one was read and parsed once (`preload`), and this is a hash lookup.
    # `load(name).render(hash)` is Crinja's own render: inside another render (a helper) it inherits that render's
    # variables. Render fragments with `render`, which starts from the global context.
    def load(template : String)
      unless @hot_reload_enabled
        loader = @preloaded || preload(strict: false)
        apply_helpers
        return loader.templates[template]? || crinja.get_template(template)
      end

      check_for_changes if should_check_for_changes?
      apply_helpers
      crinja.get_template template
    end

    # True when templates are read and parsed once instead of reloaded: every environment but development (and
    # `test` / `pipeline`, see `Configuration.hot_reload_default`), unless `template_hot_reload` says otherwise.
    def preloaded? : Bool
      !@hot_reload_enabled
    end

    @[Deprecated("Use `preloaded?`.")]
    def compiled? : Bool
      preloaded?
    end

    # :nodoc:
    # Preloads at boot (`App#prepare`) so a template with a syntax error stops the start instead of failing its
    # first request. A no-op with reload on.
    def prepare : Nil
      preload(strict: true) unless @hot_reload_enabled
    end

    # :nodoc:
    # Makes the next `load` check the files, without waiting out the interval; for specs.
    def check_now! : Nil
      @last_check = Time.utc - @check_interval - 1.second
    end

    # Enable or disable hot reloading manually
    def hot_reload=(enabled : Bool)
      @preload_lock.synchronize do
        next if enabled == @hot_reload_enabled
        @hot_reload_enabled = enabled
        @preloaded = nil
        crinja.loader = @loader.not_nil!
        update_template_mtimes if enabled
      end
    end

    # Reads and parses every template below the template directories and the error directory once, and makes the
    # result the environment's loader. Searched in order like the file system loader, the first directory that has
    # a name wins. `strict` (boot, `prepare`) raises `PreloadError` naming the template that does not parse or cannot
    # be read, and publishes nothing. Lazy (first render without `prepare`) logs it once and preloads the others;
    # the broken one stays with the file loader, which raises when it is rendered. An app `error.html` that does not
    # parse is left to the built-in fallback in both cases.
    private def preload(strict : Bool) : PreloadedLoader
      @preload_lock.synchronize do
        current = @preloaded
        # a strict preload after a lenient one (first render before `prepare`) validates again
        return current if current && (@preloaded_strict || !strict)
        publish_preloaded(parse_all(strict), strict)
      end
    end

    private def publish_preloaded(templates : Hash(String, Crinja::Template), strict : Bool) : PreloadedLoader
      preloaded = PreloadedLoader.new(templates, @loader.not_nil!)
      crinja.loader = preloaded
      @preload_count += 1
      @preloaded_strict = strict
      @preloaded = preloaded
    end

    private def parse_all(strict : Bool) : Hash(String, Crinja::Template)
      apply_helpers
      started = Time.instant
      templates = Hash(String, Crinja::Template).new
      broken = Set(String).new
      (path + [error_path]).uniq.each do |dir|
        next unless Dir.exists?(dir)
        template_names(dir, strict).sort!.each do |name|
          # a name that is broken in an earlier directory stays with the file loader, which serves that one
          next if templates.has_key?(name) || broken.includes?(name) || ignored?(name)
          file = File.join(dir, name)
          next unless File.file?(file)
          broken << name unless parse_into(templates, name, file, strict)
        end
      end
      BUILTIN.each { |name, source| templates[name] ||= Crinja::Template.new(source, crinja, name, name) }
      Log.for("azu.templates").debug { "preloaded #{templates.size} templates in #{(Time.instant - started).total_milliseconds.round(1)} ms" }
      templates
    end

    # Names relative to `dir` of the `*.html`, `*.jinja` and `*.j2` files below it, dot directories and symlinked
    # directories skipped (the file loader still serves what is in them). Walks the tree instead of globbing, so a
    # directory with `[`, `{` or `*` in its name works, and so does a trailing slash. A directory that cannot be read
    # raises `PreloadError` when strict; otherwise it is logged and skipped, and the file loader serves from it.
    private def template_names(dir : String, strict : Bool, prefix : String = "", names : Array(String) = [] of String) : Array(String)
      each_entry(dir) do |entry|
        next if entry.starts_with?('.')
        relative = prefix.empty? ? entry : "#{prefix}/#{entry}"
        full = File.join(dir, entry)
        if File.info?(full, follow_symlinks: false).try(&.directory?)
          template_names(full, strict, relative, names)
        elsif TEMPLATE_EXTENSIONS.includes?(File.extname(entry))
          names << relative
        end
      end
      names
    rescue ex : File::Error
      raise PreloadError.new("template directory #{dir}: #{ex.message}", ex) if strict
      Log.for("azu.templates").warn(exception: ex) { "template directory #{dir} was not preloaded: #{ex.message}. Templates in it may be shadowed by later directories; requests for them fall back to the file loader" }
      names
    end

    # The one place the walk reads a directory; specs override it to fail without needing a non-root user.
    private def each_entry(dir : String, & : String ->) : Nil
      Dir.each_child(dir) { |entry| yield entry }
    end

    private def ignored?(name : String) : Bool
      @preload_ignore.any? { |pattern| File.match?(pattern, name) }
    end

    # False when the file was not preloaded.
    private def parse_into(templates, name : String, file : String, strict : Bool) : Bool
      templates[name] = Crinja::Template.new(File.read(file), crinja, name, file)
      true
    rescue ex : Exception
      if BUILTIN.has_key?(name)
        Log.for("azu.templates").warn(exception: ex) { "#{file} does not parse, the built-in #{name} is used instead" }
      elsif strict
        raise PreloadError.new("template #{name} (#{file}): #{ex.message}", ex)
      else
        Log.for("azu.templates").warn(exception: ex) { "template #{name} (#{file}) was not preloaded: #{ex.message}" }
      end
      false
    end

    # One rule for the default, shared with `Configuration#template_hot_reload?`.
    private def development_environment? : Bool
      Configuration.hot_reload_default
    end

    private def initialize_loader
      @preload_lock.synchronize { rebuild_loader }
    end

    private def rebuild_loader
      loader = Crinja::Loader::ChoiceLoader.new([
        Crinja::Loader::FileSystemLoader.new((path + [error_path]).uniq).as(Crinja::Loader),
        BuiltinLoader.new(BUILTIN).as(Crinja::Loader),
      ])
      @loader = loader
      @preloaded = nil
      crinja.loader = loader
      log_shadowed_error_pages

      # Register all built-in helpers and apply to Crinja environment
      Helpers::Builtin.register_all
      apply_helpers

      update_template_mtimes if @hot_reload_enabled
    end

    @@logged = Set(String).new
    @@logged_lock = Mutex.new
    @@builtin_lock = Mutex.new
    TEMPLATE_EXTENSIONS = {".html", ".jinja", ".j2"}
    SOURCE_DIRECTORY    = File.join(__DIR__, "templates")

    # Says once per process (not on every loader rebuild) that a page of the app replaces a built-in one.
    private def log_shadowed_error_pages
      (path + [error_path]).uniq.each do |dir|
        next if dir == SOURCE_DIRECTORY
        BUILTIN.each_key do |name|
          file = File.join(dir, name)
          next unless File.file?(file)
          next unless @@logged_lock.synchronize { @@logged.add?(file) }
          Log.for("azu.templates").debug { "#{file} replaces the built-in #{name}" }
        end
      end
    end

    # Forgets what was logged once; for specs.
    def self.reset_logged! : Nil
      @@logged_lock.synchronize { @@logged.clear }
    end

    # Says once per template that the app's page failed and the built-in one was used.
    def builtin_fallback(name : String, error : Exception) : Crinja::Template
      if @@logged_lock.synchronize { @@logged.add?("fallback:#{name}") }
        Log.for("azu.templates").warn(exception: error) { "#{name} failed to load or render, the built-in page is used instead" }
      end
      builtin(name)
    end

    # The loader searches the paths it was built with, so adding one has to rebuild it, whether
    # or not hot reload is on: production never reloads, but still needs its templates found.
    private def reload_loader
      initialize_loader
    end

    private def should_check_for_changes?
      return false unless @hot_reload_enabled
      Time.utc - @last_check > @check_interval
    end

    private def check_for_changes
      @last_check = Time.utc
      return unless has_template_changes?

      Log.for("Azu::Templates").debug { "Template changes detected, reloading templates" }
      initialize_loader
    end

    private def has_template_changes? : Bool
      @template_mtimes_mutex.synchronize do
        all_paths = (path + [error_path]).uniq

        all_paths.any? do |template_path|
          next false unless Dir.exists?(template_path)

          Dir.glob(File.join(template_path, "**", "*.{html,jinja,j2}")).any? do |file_path|
            begin
              current_mtime = File.info(file_path).modification_time
              cached_mtime = @template_mtimes[file_path]?

              if cached_mtime.nil? || current_mtime > cached_mtime
                @template_mtimes[file_path] = current_mtime
                return true
              end

              false
            rescue File::NotFoundError
              # File was deleted, consider it a change
              @template_mtimes.delete(file_path)
              true
            end
          end
        end
      end
    end

    private def update_template_mtimes
      @template_mtimes_mutex.synchronize do
        @template_mtimes.clear
        all_paths = (path + [error_path]).uniq

        all_paths.each do |template_path|
          next unless Dir.exists?(template_path)

          Dir.glob(File.join(template_path, "**", "*.{html,jinja,j2}")).each do |file_path|
            begin
              @template_mtimes[file_path] = File.info(file_path).modification_time
            rescue File::NotFoundError
              # Skip files that don't exist
            end
          end
        end
      end
    end

    # Writes to the environment that renders read, so two fibers never apply at once.
    private def apply_helpers
      revision = Helpers::Registry.revision
      return if revision == @helpers_revision

      @helpers_lock.synchronize do
        next if revision == @helpers_revision
        Helpers::Registry.apply_to(crinja)
        @helpers_revision = revision
      end
    end
  end
end
