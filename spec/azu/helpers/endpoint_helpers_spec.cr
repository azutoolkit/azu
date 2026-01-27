require "../../spec_helper"

# Test response type
struct TestEndpointResponse
  include Azu::Response

  def render : String
    "OK"
  end
end

# Test endpoints for type-safe helper generation
module EndpointHelpersSpec
  # Collection endpoint (plural)
  class UsersEndpoint
    include Azu::Endpoint(TestRequest, TestEndpointResponse)

    def call : TestEndpointResponse
      TestEndpointResponse.new
    end
  end

  # Member endpoint (singular with :id)
  class UserEndpoint
    include Azu::Endpoint(TestRequest, TestEndpointResponse)

    def call : TestEndpointResponse
      TestEndpointResponse.new
    end
  end

  # POST endpoint for creating
  class CreateUserEndpoint
    include Azu::Endpoint(TestRequest, TestEndpointResponse)

    def call : TestEndpointResponse
      TestEndpointResponse.new
    end
  end

  # PUT endpoint for updating
  class UpdateUserEndpoint
    include Azu::Endpoint(TestRequest, TestEndpointResponse)

    def call : TestEndpointResponse
      TestEndpointResponse.new
    end
  end

  # DELETE endpoint
  class DeleteUserEndpoint
    include Azu::Endpoint(TestRequest, TestEndpointResponse)

    def call : TestEndpointResponse
      TestEndpointResponse.new
    end
  end
end

describe "Type-Safe Endpoint Helpers" do
  # Register the endpoints and their routes before tests
  before_all do
    # Reset registry to clean state
    Azu::Helpers::Registry.reset!

    # Register endpoints with routes - this triggers helper generation
    EndpointHelpersSpec::UsersEndpoint.get "/users"
    EndpointHelpersSpec::UserEndpoint.get "/users/:id"
    EndpointHelpersSpec::CreateUserEndpoint.post "/users"
    EndpointHelpersSpec::UpdateUserEndpoint.put "/users/:id"
    EndpointHelpersSpec::DeleteUserEndpoint.delete "/users/:id"
  end

  describe "link_to_get_* helpers" do
    it "generates link for collection endpoint" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('View Users') }}")
      result = template.render

      result.should contain "<a href=\"/users\""
      result.should contain ">View Users</a>"
    end

    it "uses path as text when no text provided" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users() }}")
      result = template.render

      result.should contain ">/users</a>"
    end

    it "generates link for member endpoint with id" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_user('View User', id='123') }}")
      result = template.render

      result.should contain "<a href=\"/users/123\""
      result.should contain ">View User</a>"
    end

    it "supports CSS class attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('Users', class='nav-link') }}")
      result = template.render

      result.should contain "class=\"nav-link\""
    end

    it "supports target attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('Users', target='_blank') }}")
      result = template.render

      result.should contain "target=\"_blank\""
    end

    it "escapes HTML in text" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('<script>alert(1)</script>') }}")
      result = template.render

      result.should contain "&lt;script&gt;"
      result.should_not contain "<script>alert"
    end
  end

  describe "link_to_post_* helpers" do
    it "generates link for POST endpoint" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_post_endpoint_helpers_spec_create_user('Create User') }}")
      result = template.render

      result.should contain "<a href=\"/users\""
      result.should contain ">Create User</a>"
    end
  end

  describe "form_for_post_* helpers" do
    it "generates POST form for collection endpoint" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_post_endpoint_helpers_spec_create_user(class='user-form') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users\""
      result.should contain "method=\"post\""
      result.should contain "class=\"user-form\""
    end

    it "does not include _method hidden field for POST" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_post_endpoint_helpers_spec_create_user() }}")
      result = template.render

      result.should_not contain "_method"
    end
  end

  describe "form_for_put_* helpers" do
    it "generates form with _method hidden field for PUT" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_put_endpoint_helpers_spec_update_user(id='123') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users/123\""
      result.should contain "method=\"post\""
      result.should contain %(<input type="hidden" name="_method" value="put">)
    end

    it "supports CSS class attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_put_endpoint_helpers_spec_update_user(id='123', class='edit-form') }}")
      result = template.render

      result.should contain "class=\"edit-form\""
    end
  end

  describe "form_for_delete_* helpers" do
    it "generates form with _method hidden field for DELETE" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_delete_endpoint_helpers_spec_delete_user(id='123') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users/123\""
      result.should contain "method=\"post\""
      result.should contain %(<input type="hidden" name="_method" value="delete">)
    end
  end

  describe "button_to_delete_* helpers" do
    it "generates delete button form" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(id='123') }}")
      result = template.render

      result.should contain "<form"
      result.should contain "action=\"/users/123\""
      result.should contain "method=\"post\""
      result.should contain %(<input type="hidden" name="_method" value="delete">)
      result.should contain "<button"
      result.should contain "type=\"submit\""
      result.should contain ">Delete</button>"
    end

    it "supports custom button text" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(text='Remove', id='123') }}")
      result = template.render

      result.should contain ">Remove</button>"
    end

    it "supports CSS class on button" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(id='123', class='btn btn-danger') }}")
      result = template.render

      result.should contain "class=\"btn btn-danger\""
    end

    it "supports confirm attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(id='123', confirm='Are you sure?') }}")
      result = template.render

      result.should contain "onclick=\"return confirm('Are you sure?')\""
    end

    it "escapes HTML in text" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(text='<b>Delete</b>', id='123') }}")
      result = template.render

      result.should contain "&lt;b&gt;Delete&lt;/b&gt;"
      result.should_not contain "<b>Delete</b>"
    end

    it "supports custom params as hidden fields" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ button_to_delete_endpoint_helpers_spec_delete_user(id='123', params={'redirect': '/users', 'source': 'list'}) }}")
      result = template.render

      result.should contain %(<input type="hidden" name="redirect" value="/users">)
      result.should contain %(<input type="hidden" name="source" value="list">)
    end
  end

  describe "link_to_* with params" do
    it "adds query parameters to URL" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('Users', params={'page': '2', 'per_page': '10'}) }}")
      result = template.render

      result.should contain "href=\"/users?"
      result.should contain "page=2"
      result.should contain "per_page=10"
    end

    it "adds query parameters to URL with id" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_user('View', id='123', params={'tab': 'profile'}) }}")
      result = template.render

      result.should contain "href=\"/users/123?"
      result.should contain "tab=profile"
    end

    it "URL-encodes parameter values" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ link_to_get_endpoint_helpers_spec_users('Users', params={'query': 'hello world'}) }}")
      result = template.render

      # URI.encode_www_form uses + for spaces (standard form encoding)
      result.should contain "query=hello+world"
    end
  end

  describe "form_for_* with params" do
    it "adds hidden fields for params" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_post_endpoint_helpers_spec_create_user(params={'redirect_to': '/dashboard', 'source': 'signup'}) }}")
      result = template.render

      result.should contain %(<input type="hidden" name="redirect_to" value="/dashboard">)
      result.should contain %(<input type="hidden" name="source" value="signup">)
    end

    it "adds hidden fields for params with PUT method" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_put_endpoint_helpers_spec_update_user(id='123', params={'return_url': '/users'}) }}")
      result = template.render

      result.should contain %(<input type="hidden" name="_method" value="put">)
      result.should contain %(<input type="hidden" name="return_url" value="/users">)
    end

    it "escapes HTML in param values" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ form_for_post_endpoint_helpers_spec_create_user(params={'msg': '<script>alert(1)</script>'}) }}")
      result = template.render

      result.should contain "&lt;script&gt;"
      result.should_not contain "<script>alert"
    end
  end

  describe "helper availability" do
    it "registers link helpers in the registry" do
      Azu::Helpers::Registry.has_function?(:link_to_get_endpoint_helpers_spec_users).should be_true
      Azu::Helpers::Registry.has_function?(:link_to_get_endpoint_helpers_spec_user).should be_true
      Azu::Helpers::Registry.has_function?(:link_to_post_endpoint_helpers_spec_create_user).should be_true
      Azu::Helpers::Registry.has_function?(:link_to_put_endpoint_helpers_spec_update_user).should be_true
      Azu::Helpers::Registry.has_function?(:link_to_delete_endpoint_helpers_spec_delete_user).should be_true
    end

    it "registers form helpers for non-GET methods" do
      Azu::Helpers::Registry.has_function?(:form_for_post_endpoint_helpers_spec_create_user).should be_true
      Azu::Helpers::Registry.has_function?(:form_for_put_endpoint_helpers_spec_update_user).should be_true
      Azu::Helpers::Registry.has_function?(:form_for_delete_endpoint_helpers_spec_delete_user).should be_true
    end

    it "does not register form helper for GET method" do
      Azu::Helpers::Registry.has_function?(:form_for_get_endpoint_helpers_spec_users).should be_false
      Azu::Helpers::Registry.has_function?(:form_for_get_endpoint_helpers_spec_user).should be_false
    end

    it "registers button_to_delete helper only for DELETE endpoints" do
      Azu::Helpers::Registry.has_function?(:button_to_delete_endpoint_helpers_spec_delete_user).should be_true
    end
  end
end
