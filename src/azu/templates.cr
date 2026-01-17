require "crinja"

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
    @loader : Crinja::Loader::FileSystemLoader?
    @template_mtimes : Hash(String, Time) = Hash(String, Time).new
    @template_mtimes_mutex : Mutex = Mutex.new
    @last_check : Time = Time.utc
    @check_interval : Time::Span = 1.second
    @hot_reload_enabled : Bool = false
    @file_watcher_started : Bool = false

    getter crinja = Crinja.new
    getter path : Array(String)
    getter error_path : String

    module Renderable
      private def view(template : String = page_path, data = Hash(String, String).new)
        CONFIG.templates.load(template).render(data)
      end

      def page_path
        "#{self.class.name.split("::").join("/").underscore.downcase}.jinja"
      end
    end

    def initialize(@path : Array(String), @error_path : String, hot_reload : Bool? = nil)
      @hot_reload_enabled = hot_reload.nil? ? development_environment? : hot_reload
      initialize_loader
      start_file_watcher if @hot_reload_enabled
    end

    def path=(path : String)
      @path << Path[path].expand.to_s
      reload_loader_if_needed
    end

    def error_path=(path : String)
      @error_path = Path[path].expand.to_s
      reload_loader_if_needed
    end

    def load(template : String)
      check_for_changes if should_check_for_changes?
      crinja.get_template template
    end

    # Enable or disable hot reloading manually
    def hot_reload=(enabled : Bool)
      @hot_reload_enabled = enabled
      start_file_watcher if enabled
    end

    private def development_environment?
      env = ENV.fetch("CRYSTAL_ENV", "development").downcase
      env == "development" || env == "test"
    end

    private def initialize_loader
      all_paths = ([error_path] + path).uniq
      @loader = Crinja::Loader::FileSystemLoader.new(all_paths)
      crinja.loader = @loader.as(Crinja::Loader::FileSystemLoader)
      update_template_mtimes if @hot_reload_enabled
    end

    private def reload_loader_if_needed
      return unless @hot_reload_enabled
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
        all_paths = ([error_path] + path).uniq

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
        all_paths = ([error_path] + path).uniq

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

    private def start_file_watcher
      return if @file_watcher_started
      @file_watcher_started = true

      spawn(name: "template-watcher") do
        loop do
          sleep @check_interval
          # File system watching is handled in check_for_changes method
          # This keeps the background process lightweight
        end
      rescue ex
        Log.for("Azu::Templates").error(exception: ex) { "Template file watcher failed" }
        @file_watcher_started = false
      end
    end
  end
end
