require "../../../spec_helper"

describe "URL Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::UrlHelpers.register
  end

  describe "link_to" do
    it "generates an anchor tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('Home', '/') }}")
      result = template.render

      result.should eq "<a href=\"/\">Home</a>"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('Home', '/', class='nav-link') }}")
      result = template.render

      result.should contain "class=\"nav-link\""
      result.should contain "href=\"/\""
      result.should contain ">Home</a>"
    end

    it "supports target attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('Docs', '/docs', target='_blank') }}")
      result = template.render

      result.should contain "target=\"_blank\""
    end

    it "supports id attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('Home', '/', id='home-link') }}")
      result = template.render

      result.should contain "id=\"home-link\""
    end

    it "escapes HTML in text" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('<script>', '/') }}")
      result = template.render

      result.should contain "&lt;script&gt;"
      result.should_not contain "<script>"
    end

    it "escapes HTML in URL" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to('Test', '/test?a=1&b=2') }}")
      result = template.render

      result.should contain "href=\"/test?a=1&amp;b=2\""
    end
  end

  describe "button_to" do
    it "generates a form with button" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to('Delete', '/users/1', method='delete') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users/1\""
      result.should contain "<button"
      result.should contain "type=\"submit\""
      result.should contain "_method"
      result.should contain "delete"
      result.should contain "</form>"
    end

    it "supports CSS class on button" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to('Delete', '/users/1', class='btn btn-danger') }}")
      result = template.render

      result.should contain "class=\"btn btn-danger\""
    end

    it "supports confirm attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to('Delete', '/users/1', confirm='Are you sure?') }}")
      result = template.render

      result.should contain "data-confirm=\"Are you sure?\""
    end
  end

  describe "mail_to" do
    it "generates a mailto link" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ mail_to('test@example.com', 'Email Us') }}")
      result = template.render

      result.should contain "href=\"mailto:test@example.com\""
      result.should contain ">Email Us</a>"
    end

    it "uses email as text when no text provided" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ mail_to('test@example.com') }}")
      result = template.render

      result.should contain ">test@example.com</a>"
    end

    it "supports subject parameter" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ mail_to('test@example.com', 'Email', subject='Hello') }}")
      result = template.render

      result.should contain "subject=Hello"
    end

    it "supports body parameter" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ mail_to('test@example.com', 'Email', body='Message') }}")
      result = template.render

      result.should contain "body=Message"
    end
  end

  describe "current_path" do
    it "returns current path from context" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ current_path() }}")
      result = template.render

      result.should eq "/"
    end

    it "returns empty string when no context" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ current_path() }}")
      result = template.render

      result.should eq ""
    end
  end

  describe "is_current_page filter" do
    it "returns true when path matches current_path" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{% if '/' | is_current_page %}yes{% endif %}")
      result = template.render

      result.should eq "yes"
    end

    it "returns false when path doesn't match" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/about"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{% if '/' | is_current_page %}yes{% else %}no{% endif %}")
      result = template.render

      result.should eq "no"
    end
  end

  describe "active_class filter" do
    it "returns class when path matches current_path" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '/' | active_class('active') }}")
      result = template.render

      result.should eq "active"
    end

    it "returns empty string when path doesn't match" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/about"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '/' | active_class('active') }}")
      result = template.render

      result.should eq ""
    end

    it "supports custom inactive class" do
      crinja = Crinja.new
      crinja.context["current_path"] = "/about"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '/' | active_class('active', 'inactive') }}")
      result = template.render

      result.should eq "inactive"
    end
  end

  describe "back_url" do
    it "returns referer from context when available" do
      crinja = Crinja.new
      crinja.context["http_referer"] = "/previous"
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ back_url() }}")
      result = template.render

      result.should eq "/previous"
    end

    it "returns fallback when no referer" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ back_url(fallback='/') }}")
      result = template.render

      result.should eq "/"
    end

    it "defaults fallback to root" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ back_url() }}")
      result = template.render

      result.should eq "/"
    end
  end
end
