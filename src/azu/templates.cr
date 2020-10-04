module Azu
  class Templates
    private getter crinja = Crinja.new
    getter path : String
    getter error_path : String

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
