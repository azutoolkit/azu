module Azu
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
