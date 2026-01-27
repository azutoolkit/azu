require "../../../spec_helper"

describe "Form Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::FormHelpers.register
  end

  describe "form_tag" do
    it "generates a form opening tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_tag('/users', method='post') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users\""
      result.should contain "method=\"post\""
    end

    it "defaults method to post" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_tag('/users') }}")
      result = template.render

      result.should contain "method=\"post\""
    end

    it "supports additional attributes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_tag('/users', class='my-form', id='user-form') }}")
      result = template.render

      result.should contain "class=\"my-form\""
      result.should contain "id=\"user-form\""
    end

    it "sets enctype for multipart when specified" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_tag('/upload', multipart=true) }}")
      result = template.render

      result.should contain "enctype=\"multipart/form-data\""
    end
  end

  describe "end_form" do
    it "generates closing form tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ end_form() }}")
      result = template.render

      result.should eq "</form>"
    end
  end

  describe "text_field" do
    it "generates a text input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ text_field('user', 'name') }}")
      result = template.render

      result.should contain "<input"
      result.should contain "type=\"text\""
      result.should contain "name=\"user[name]\""
      result.should contain "id=\"user_name\""
    end

    it "supports value attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ text_field('user', 'name', value='John') }}")
      result = template.render

      result.should contain "value=\"John\""
    end

    it "supports placeholder attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ text_field('user', 'name', placeholder='Enter name') }}")
      result = template.render

      result.should contain "placeholder=\"Enter name\""
    end

    it "supports required attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ text_field('user', 'name', required=true) }}")
      result = template.render

      result.should contain "required"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ text_field('user', 'name', class='form-control') }}")
      result = template.render

      result.should contain "class=\"form-control\""
    end
  end

  describe "email_field" do
    it "generates an email input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ email_field('user', 'email') }}")
      result = template.render

      result.should contain "type=\"email\""
      result.should contain "name=\"user[email]\""
    end
  end

  describe "password_field" do
    it "generates a password input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ password_field('user', 'password') }}")
      result = template.render

      result.should contain "type=\"password\""
      result.should contain "name=\"user[password]\""
    end
  end

  describe "number_field" do
    it "generates a number input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ number_field('product', 'quantity') }}")
      result = template.render

      result.should contain "type=\"number\""
      result.should contain "name=\"product[quantity]\""
    end

    it "supports min and max attributes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ number_field('product', 'quantity', min=1, max=100) }}")
      result = template.render

      result.should contain "min=\"1\""
      result.should contain "max=\"100\""
    end

    it "supports step attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ number_field('product', 'price', step='0.01') }}")
      result = template.render

      result.should contain "step=\"0.01\""
    end
  end

  describe "textarea" do
    it "generates a textarea" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ textarea('post', 'content') }}")
      result = template.render

      result.should contain "<textarea"
      result.should contain "name=\"post[content]\""
      result.should contain "id=\"post_content\""
      result.should contain "</textarea>"
    end

    it "supports rows and cols" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ textarea('post', 'content', rows=5, cols=40) }}")
      result = template.render

      result.should contain "rows=\"5\""
      result.should contain "cols=\"40\""
    end

    it "supports value/content" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ textarea('post', 'content', value='Hello World') }}")
      result = template.render

      result.should contain ">Hello World</textarea>"
    end
  end

  describe "hidden_field" do
    it "generates a hidden input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ hidden_field('user', 'id', value='123') }}")
      result = template.render

      result.should contain "type=\"hidden\""
      result.should contain "name=\"user[id]\""
      result.should contain "value=\"123\""
    end
  end

  describe "checkbox" do
    it "generates a checkbox input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ checkbox('user', 'active') }}")
      result = template.render

      result.should contain "type=\"checkbox\""
      result.should contain "name=\"user[active]\""
    end

    it "includes hidden field for unchecked state" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ checkbox('user', 'active') }}")
      result = template.render

      result.should contain "type=\"hidden\""
      result.should contain "value=\"0\""
    end

    it "supports checked attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ checkbox('user', 'active', checked=true) }}")
      result = template.render

      result.should contain "checked"
    end
  end

  describe "radio_button" do
    it "generates a radio input" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ radio_button('user', 'role', value='admin') }}")
      result = template.render

      result.should contain "type=\"radio\""
      result.should contain "name=\"user[role]\""
      result.should contain "value=\"admin\""
    end

    it "supports checked attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ radio_button('user', 'role', value='admin', checked=true) }}")
      result = template.render

      result.should contain "checked"
    end
  end

  describe "select_field" do
    it "generates a select dropdown" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string(<<-TEMPLATE)
      {{ select_field('user', 'role', options=[
        {"value": "user", "label": "User"},
        {"value": "admin", "label": "Admin"}
      ]) }}
      TEMPLATE
      result = template.render

      result.should contain "<select"
      result.should contain "name=\"user[role]\""
      result.should contain "<option"
      result.should contain "value=\"user\""
      result.should contain ">User</option>"
      result.should contain "value=\"admin\""
      result.should contain ">Admin</option>"
      result.should contain "</select>"
    end

    it "marks selected option" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string(<<-TEMPLATE)
      {{ select_field('user', 'role', options=[
        {"value": "user", "label": "User"},
        {"value": "admin", "label": "Admin"}
      ], selected='admin') }}
      TEMPLATE
      result = template.render

      result.should match /value="admin"[^>]*selected/
    end

    it "supports include_blank option" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string(<<-TEMPLATE)
      {{ select_field('user', 'role', options=[
        {"value": "user", "label": "User"}
      ], include_blank='Select...') }}
      TEMPLATE
      result = template.render

      result.should contain ">Select...</option>"
    end
  end

  describe "label_tag" do
    it "generates a label element" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ label_tag('user_name', 'Full Name') }}")
      result = template.render

      result.should contain "<label"
      result.should contain "for=\"user_name\""
      result.should contain ">Full Name</label>"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ label_tag('user_name', 'Name', class='form-label') }}")
      result = template.render

      result.should contain "class=\"form-label\""
    end
  end

  describe "submit_button" do
    it "generates a submit button" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ submit_button('Save') }}")
      result = template.render

      result.should contain "<button"
      result.should contain "type=\"submit\""
      result.should contain ">Save</button>"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ submit_button('Save', class='btn btn-primary') }}")
      result = template.render

      result.should contain "class=\"btn btn-primary\""
    end

    it "supports disabled attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ submit_button('Save', disabled=true) }}")
      result = template.render

      result.should contain "disabled"
    end
  end
end
