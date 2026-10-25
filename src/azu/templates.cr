require "crinja"
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
    @compiled : CompiledLoader?
    @compile_lock : Mutex = Mutex.new

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
    class CompileError < Exception
    end

    # :nodoc:
    # Every template found below the template directories, read and parsed once, as an immutable name => template
    # map. `Templates` publishes it with a single assignment, so a request only ever sees a complete map. Includes
    # and extends resolve through it too, because it is the Crinja environment's loader. A name that is not in the
    # map (a file added after boot, a path like `./a//b`, another extension) goes to the loader it wraps.
    class CompiledLoader < Crinja::Loader
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

        # Inject HTTP context variables if context is available
        {% if @type.has_method?(:context) %}
          if ctx = (context rescue nil)
            template_context = Helpers::TemplateContext.new(ctx)
            template_context.to_template_vars.each do |key, value|
              template_data[key] = value unless template_data.has_key?(key)
            end
          end
        {% end %}

        Azu.current_config.templates.load(template).render(template_data)
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
        template_context = Helpers::TemplateContext.new(http_context)

        template_context.to_template_vars.each do |key, value|
          template_data[key] = value unless template_data.has_key?(key)
        end

        Azu.current_config.templates.load(template).render(template_data)
      end

      def page_path
        "#{self.class.name.split("::").join("/").underscore.downcase}.jinja"
      end
    end

    def initialize(@path : Array(String), @error_path : String, hot_reload : Bool? = nil)
      @hot_reload_enabled = hot_reload.nil? ? development_environment? : hot_reload
      initialize_loader
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
      env = @@builtin_lock.synchronize { @builtin_crinja ||= Crinja.new.tap { |crinja| crinja.loader = BuiltinLoader.new(BUILTIN) } }
      env.get_template(name)
    end

    # With reload on (development) every call may re-read changed files, see `check_for_changes`. Without it the
    # templates are compiled: each one was read and parsed once (`compile`), and this is a hash lookup.
    def load(template : String)
      unless @hot_reload_enabled
        loader = @compiled || compile
        apply_helpers
        return loader.templates[template]? || crinja.get_template(template)
      end

      check_for_changes if should_check_for_changes?
      apply_helpers
      crinja.get_template template
    end

    # True when templates are read and parsed once instead of reloaded: every environment but development (and
    # `test` / `pipeline`, see `Configuration.hot_reload_default`), unless `template_hot_reload` says otherwise.
    def compiled? : Bool
      !@hot_reload_enabled
    end

    # :nodoc:
    # Compiles at boot (`App#prepare`) so a template with a syntax error stops the start instead of failing its
    # first request. A no-op with reload on.
    def prepare : Nil
      compile unless @hot_reload_enabled
    end

    # Enable or disable hot reloading manually
    def hot_reload=(enabled : Bool)
      @compile_lock.synchronize do
        @hot_reload_enabled = enabled
        @compiled = nil
        crinja.loader = @loader.not_nil!
        update_template_mtimes if enabled
      end
    end

    # Reads and parses every template below the template directories and the error directory once, and makes the
    # result the environment's loader. Searched in order like the file system loader, the first directory that has
    # a name wins. Raises `CompileError` naming the template that does not parse; an error page of the app
    # (`error.html`) that does not parse is left to the built-in fallback instead.
    private def compile : CompiledLoader
      @compile_lock.synchronize do
        @compiled || publish_compiled(parse_all)
      end
    end

    private def publish_compiled(templates : Hash(String, Crinja::Template)) : CompiledLoader
      compiled = CompiledLoader.new(templates, @loader.not_nil!)
      crinja.loader = compiled
      @compiled = compiled
    end

    private def parse_all : Hash(String, Crinja::Template)
      apply_helpers
      templates = Hash(String, Crinja::Template).new
      (path + [error_path]).uniq.each do |dir|
        Dir.glob(File.join(dir, "**", "*.{html,jinja,j2}")).sort!.each do |file|
          name = file[(dir.size + 1)..]
          next if templates.has_key?(name) || !File.file?(file)
          parse_into(templates, name, File.read(file), file)
        end
      end
      BUILTIN.each { |name, source| parse_into(templates, name, source, name) unless templates.has_key?(name) }
      templates
    end

    private def parse_into(templates, name : String, source : String, filename : String) : Nil
      templates[name] = Crinja::Template.new(source, crinja, name, filename)
    rescue ex : Crinja::Error
      raise CompileError.new("template #{name} (#{filename}): #{ex.message}", ex) unless BUILTIN.has_key?(name)
      Log.for("azu.templates").warn(exception: ex) { "#{filename} does not parse, the built-in #{name} is used instead" }
    end

    private def development_environment?
      env = Env.environment
      env == "development" || env == "test"
    end

    private def initialize_loader
      loader = Crinja::Loader::ChoiceLoader.new([
        Crinja::Loader::FileSystemLoader.new((path + [error_path]).uniq).as(Crinja::Loader),
        BuiltinLoader.new(BUILTIN).as(Crinja::Loader),
      ])
      @loader = loader
      @compiled = nil
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
    SOURCE_DIRECTORY = File.join(__DIR__, "templates")

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

    private def apply_helpers
      revision = Helpers::Registry.revision
      return if revision == @helpers_revision

      Helpers::Registry.apply_to(crinja)
      @helpers_revision = revision
    end
  end
end
