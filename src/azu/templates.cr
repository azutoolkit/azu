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
    private getter crinja = Crinja.new
    getter path : String
    getter error_path : String

    module Renderable
      private def render(template : String = page_path, data = Hash(String, String).new)
        CONFIG.templates.load(template).render(data)
      end

      def page_path
        "#{self.class.name.split("::")[1..-1].join("/").underscore.downcase}.jinja"
      end
    end

    def initialize(@path : String, @error_path : String)
      crinja.loader = Crinja::Loader::FileSystemLoader.new([path, error_path])
    end

    def path=(path : String)
      reload { @path = Path[path].expand.to_s }
    end

    def error_path=(path : String)
      reload { @error_path = Path[path].expand.to_s }
    end

    def load(template : String)
      crinja.get_template template
    end

    private def reload
      with self yield
      crinja.loader = Crinja::Loader::FileSystemLoader.new([path, error_path])
    end
  end
end
