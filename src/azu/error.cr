require "ecr"
require "exception_page"

module Azu
  # :nodoc:
  class ExceptionPage < ::ExceptionPage
    def styles : ExceptionPage::Styles
      ::ExceptionPage::Styles.new(
        accent: "red",
      )
    end
  end
end
