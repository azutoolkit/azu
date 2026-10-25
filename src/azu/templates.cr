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
      (@builtin_crinja ||= Crinja.new.tap { |env| env.loader = BuiltinLoader.new(BUILTIN) }).get_template(name)
    end

    def load(template : String)
      check_for_changes if should_check_for_changes?
      apply_helpers
      crinja.get_template template
    end

    # Enable or disable hot reloading manually
    def hot_reload=(enabled : Bool)
      @hot_reload_enabled = enabled
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
      crinja.loader = loader
      log_shadowed_error_pages

      # Register all built-in helpers and apply to Crinja environment
      Helpers::Builtin.register_all
      apply_helpers

      update_template_mtimes if @hot_reload_enabled
    end

    private def log_shadowed_error_pages
      BUILTIN.each_key do |name|
        shadow = path.find { |dir| File.file?(File.join(dir, name)) }
        Log.for("azu.templates").debug { "#{File.join(shadow, name)} replaces the built-in #{name}" } if shadow
      end
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
