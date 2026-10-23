require "../spec_helper"
require "../support/integration_helpers"

module Azu::EndpointDslSpec
  extend IntegrationHelpers

  class CreateUser < Azu::Endpoint
    post "/dsl/users", as: :dsl_users

    params do
      param :email, String, required: true, format: :email
      param :name, String, min_length: 2, max_length: 10
      param :age, Int32, min: 18, max: 120, default: 30
      param :role, String, default: "member", in: %w(member admin)
    end

    def call
      render :created, params.to_h
    end
  end

  class ShowUser < Azu::Endpoint
    get "/dsl/users/:id", as: :dsl_user

    params do
      param :id, Int32, required: true
      param :verbose, Bool
    end

    def call
      render({id: params.id, verbose: params.verbose})
    end
  end

  class Guarded < Azu::Endpoint
    get "/dsl/guarded"

    before_action :authenticate!
    before_action { header "X-Seen", "yes" }
    after_action { header "X-After", "ran" }

    def call
      "secret"
    end

    private def authenticate!
      render :unauthorized, errors: ["Sign in first"] unless header["Authorization"]?
    end
  end

  class NotFoundError < Exception
  end

  class Rescuing < Azu::Endpoint
    get "/dsl/rescue"

    rescue_from(NotFoundError) { |ex| render :not_found, errors: [ex.message] }
    rescue_from ArgumentError, with: :bad_arg

    def call
      raise NotFoundError.new("no such thing") if raw_params["kind"]? == "missing"
      raise ArgumentError.new("nope") if raw_params["kind"]? == "arg"
      raise "boom"
    end

    private def bad_arg(ex)
      render :bad_request, errors: [ex.message]
    end
  end

  class Implicit < Azu::Endpoint
    get "/dsl/implicit"

    def call
      {status: "up"}
    end
  end

  class Redirecting < Azu::Endpoint
    post "/dsl/redirect"

    def call
      session[:user_id] = "42"
      redirect_to "/home", :see_other, notice: "Welcome"
    end
  end

  class Reader < Azu::Endpoint
    get "/dsl/reader"

    def call
      render({user: session[:user_id]?, notice: flash.notice})
    end
  end

  class Twice < Azu::Endpoint
    get "/dsl/twice"

    def call
      render :ok, "a"
      render :ok, "b"
    end
  end

  class BadStatus < Azu::Endpoint
    get "/dsl/bad_status"

    def call
      render :teapot_ish, "x"
    end
  end

  class Cached < Azu::Endpoint
    get "/dsl/cached"
    cache_for 1.minute

    @@calls = 0

    def self.calls
      @@calls
    end

    def call
      @@calls += 1
      render({calls: @@calls})
    end
  end

  class Plain < Azu::Endpoint
    get "/dsl/plain"

    def call
      head :no_content
    end
  end

  class Sender < Azu::Endpoint
    get "/dsl/send"

    def call
      send_data "a,b\n1,2\n", type: "text/csv", filename: "x.csv"
    end
  end

  def self.run(endpoint : Azu::Endpoint, method = "GET", path = "/", body : String? = nil, headers = HTTP::Headers.new, path_params = {} of String => String)
    headers["Content-Type"] ||= "application/json" if body
    context, io = create_context(method, path, headers, body)
    context.request.path_params = path_params
    endpoint.call(context)
    context.response.close
    io.rewind
    text = io.gets_to_end
    status = text.lines.first.split(' ')[1].to_i
    head, _, payload = text.partition("\r\n\r\n")
    {status, payload, context.response.headers, head}
  end
end

describe Azu::Endpoint do
  describe "params" do
    it "validates and renders a symbolic status" do
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::CreateUser.new, "POST", "/dsl/users", %({"email":"a@b.co","name":"Al"}))
      status.should eq 201
      JSON.parse(body).should eq JSON.parse(%({"email":"a@b.co","name":"Al","age":30,"role":"member"}))
    end

    it "answers 422 with the invalid fields" do
      ex = expect_raises(Azu::Response::ValidationError) do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::CreateUser.new, "POST", "/dsl/users", %({"email":"nope","name":"A","age":5,"role":"root"}))
      end
      ex.status.should eq HTTP::Status::UNPROCESSABLE_ENTITY
      ex.field_errors.keys.sort!.should eq %w(age email name role)
      ex.field_errors["name"].should eq ["is too short (minimum is 2)"]
    end

    it "reports missing required fields" do
      ex = expect_raises(Azu::Response::ValidationError) do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::CreateUser.new, "POST", "/dsl/users", "{}")
      end
      ex.field_errors["email"].should eq ["is required"]
    end

    it "reads form bodies" do
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::CreateUser.new, "POST", "/dsl/users", "email=a%40b.co&name=Al&age=40", headers)
      status.should eq 201
      JSON.parse(body)["age"].as_i.should eq 40
    end

    it "answers 400 for malformed input" do
      expect_raises(Azu::Response::BadRequest) do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::CreateUser.new, "POST", "/dsl/users", "{not json")
      end
    end

    it "takes path params with a GET" do
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::ShowUser.new, "GET", "/dsl/users/7?verbose=true", nil, HTTP::Headers.new, {"id" => "7"})
      status.should eq 200
      JSON.parse(body).should eq JSON.parse(%({"id":7,"verbose":true}))
    end

    it "lets path params complete a JSON body" do
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::ShowUser.new, "PUT", "/dsl/users/9", %({"verbose":false}), HTTP::Headers.new, {"id" => "9"})
      status.should eq 200
      JSON.parse(body)["id"].as_i.should eq 9
    end
  end

  describe "hooks" do
    it "halts when a before_action renders" do
      status, body, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Guarded.new)
      status.should eq 401
      JSON.parse(body)["errors"].as_a.map(&.as_s).should eq ["Sign in first"]
      headers["X-Seen"]?.should be_nil
    end

    it "runs before and after actions and renders a String result" do
      status, body, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Guarded.new, "GET", "/dsl/guarded", nil, HTTP::Headers{"Authorization" => "x"})
      status.should eq 200
      body.should eq "secret"
      headers["X-Seen"].should eq "yes"
      headers["X-After"].should eq "ran"
    end

    it "maps exceptions with rescue_from" do
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Rescuing.new, "GET", "/dsl/rescue?kind=missing")
      status.should eq 404
      JSON.parse(body)["errors"][0].as_s.should eq "no such thing"

      status, _, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Rescuing.new, "GET", "/dsl/rescue?kind=arg")
      status.should eq 400
    end

    it "lets unmapped exceptions propagate" do
      expect_raises(Exception, "boom") do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Rescuing.new, "GET", "/dsl/rescue")
      end
    end
  end

  describe "rendering" do
    it "renders what call returns" do
      status, body, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Implicit.new)
      status.should eq 200
      body.should eq %({"status":"up"})
      headers["Content-Type"].should contain "application/json"
    end

    it "supports head" do
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Plain.new)
      status.should eq 204
      body.should eq ""
    end

    it "refuses to render twice" do
      expect_raises(Azu::Endpoint::DoubleRenderError) do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Twice.new)
      end
    end

    it "explains unknown status names" do
      expect_raises(ArgumentError, /Unknown status :teapot_ish/) do
        Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::BadStatus.new)
      end
    end

    it "sends data as an attachment" do
      status, body, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Sender.new)
      status.should eq 200
      body.should eq "a,b\n1,2\n"
      headers["Content-Disposition"].should eq %(attachment; filename="x.csv")
    end
  end

  describe "session and flash" do
    it "redirects with a signed session cookie and flash" do
      status, _, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Redirecting.new, "POST", "/dsl/redirect")
      status.should eq 303
      headers["Location"].should eq "/home"
      cookies = headers.get("Set-Cookie")
      cookies.any?(&.starts_with?("_azu_session=")).should be_true
      cookies.any?(&.starts_with?("_flash=")).should be_true
    end

    it "reads them back on the next request and rejects forged cookies" do
      _, _, headers, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Redirecting.new, "POST", "/dsl/redirect")
      jar = headers.get("Set-Cookie").map { |line| line.split(';').first }.join("; ")
      status, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Reader.new, "GET", "/dsl/reader", nil, HTTP::Headers{"Cookie" => jar})
      status.should eq 200
      JSON.parse(body).should eq JSON.parse(%({"user":"42","notice":"Welcome"}))

      forged = jar.sub(/_azu_session=[^.;]+/) { "_azu_session=#{Base64.urlsafe_encode(%({"user_id":"1"}), padding: false)}" }
      _, body, _ = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Reader.new, "GET", "/dsl/reader", nil, HTTP::Headers{"Cookie" => forged})
      JSON.parse(body)["user"].raw.should be_nil
    end
  end

  describe "cache_for" do
    it "serves the second request from the cache" do
      Azu.cache.clear if Azu.cache.responds_to?(:clear)
      first = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Cached.new, "GET", "/dsl/cached?t=#{Random.rand(1_000_000)}")
      path = "/dsl/cached?t=same#{Random.rand(1_000_000)}"
      a = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Cached.new, "GET", path)
      b = Azu::EndpointDslSpec.run(Azu::EndpointDslSpec::Cached.new, "GET", path)
      a[1].should eq b[1]
      b[2]["X-Azu-Cache"]?.should eq "HIT"
      first[0].should eq 200
    end
  end

  describe "named routes" do
    it "expands them" do
      Azu::Routes.path(:dsl_user, id: 5).should eq "/dsl/users/5"
      Azu::Routes.path(:dsl_users).should eq "/dsl/users"
    end

    it "explains unknown names" do
      expect_raises(ArgumentError, /Unknown route :nope/) { Azu::Routes.path(:nope) }
    end

    it "encodes values" do
      Azu::Routes.expand("/files/:name", name: "a b/c").should eq "/files/a%20b%2Fc"
    end
  end

  describe "router builder" do
    it "scopes, nests and mounts endpoint classes" do
      router = Azu::Router.new
      router.routes("/api") do
        get "/ping", Azu::EndpointDslSpec::Implicit
        namespace "/v2" do
          get "/ping", Azu::EndpointDslSpec::Plain, as: :ping_v2
        end
        resources "/widgets", index: Azu::EndpointDslSpec::Implicit, show: Azu::EndpointDslSpec::Plain
      end

      paths = router.route_info.map { |info| "#{info[:method]} #{info[:path]}" } rescue [] of String
      Azu::Routes.path(:ping_v2).should eq "/api/v2/ping"
      Azu::Routes.path(:widget, id: 3).should eq "/api/widgets/3"
      Azu::Routes.path(:widgets).should eq "/api/widgets"
      paths.should_not be_nil
    end

    it "singularizes resource names" do
      Azu::Router.singularize("posts").should eq "post"
      Azu::Router.singularize("categories").should eq "category"
      Azu::Router.singularize("boxes").should eq "box"
      Azu::Router.singularize("news").should eq "news"
    end
  end
end

describe Azu::Configuration do
  it "builds a handler stack and runs environment blocks" do
    config = Azu::Configuration.new
    config.handlers do
      use Azu::Handler::RequestId.new
      use_if false, Azu::Handler::Rescuer.new
    end
    config.pipeline.size.should eq 1

    config.env = Azu::Environment::Production
    ran = [] of String
    config.production { ran << "production" }
    config.development { ran << "development" }
    config.on(:staging, :production) { ran << "on" }
    ran.should eq ["production", "on"]
  end
end
