module Azu
 
  module Response
    # Templates are used by Azu when rendering responses.
    # 
    # Since many views render significant content, for example a whole HTML file, 
    # it is common to put these files into a particular directory, typically `src/templates`.
    # This module provides conveniences for reading all files from a particular directory and embedding 
    # them into a single module. Imagine you have a directory with templates:
    #
    # ```crystal
    # module MyApp
    #   class Home::Page
    #     include Response::Html
    #
    #     TEMPLATE_PATH = "home/index.jinja"
    #
    #     def html
    #       render TEMPLATE_PATH, assigns
    #     end
    #     
    #     def assigns
    #       {
    #         "welcome"  => "Hello World!"
    #       }
    #     end
    #   end
    # end
    # ```
    # Templates will define a private method named `#render` with one clause per file system template. 
    # We expose this private function via render/2, which can be invoked as:
    # 
    # ```crystal
    # render(template : String, data)
    # ```
    module Html
      include Response

      abstract def html

      getter templates : Templates = CONFIG.templates

      def render(template : String, data)
        templates.load(template).render(data)
      end

      def to_s
        html
      end
    end
  end
end
