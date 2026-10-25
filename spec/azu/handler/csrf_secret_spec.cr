require "../../spec_helper"
require "log/spec"

private def csrf_context(method : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Server::Context
  HTTP::Server::Context.new(HTTP::Request.new(method, "/", headers), HTTP::Server::Response.new(IO::Memory.new))
end

private def with_csrf_env(vars : Hash(String, String?), &)
  saved = vars.keys.to_h { |name| {name, ENV[name]?} }
  vars.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  Azu::Env.reset_generated_secrets!
  Azu::Handler::CSRF.reset_default!
  begin
    yield
  ensure
    saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
    Azu::Env.reset_generated_secrets!
    Azu::Handler::CSRF.reset_default!
  end
end

# A token signed by one process must verify in another, and a deployment without a secret must not boot with a
# key that only this process knows.
describe "CSRF signing secret" do
  it "refuses to build a handler in production when CSRF_SECRET is not set" do
    with_csrf_env({"CRYSTAL_ENV" => "production", "CSRF_SECRET" => nil}) do
      error = expect_raises(Azu::Env::MissingError) { Azu::Handler::CSRF.new }
      error.message.to_s.should contain "CSRF_SECRET is not set"
    end
  end

  it "refuses in production for the default instance and for configure when the block sets no secret" do
    with_csrf_env({"CRYSTAL_ENV" => "production", "CSRF_SECRET" => nil}) do
      expect_raises(Azu::Env::MissingError) { Azu::Handler::CSRF.default }
      expect_raises(Azu::Env::MissingError) { Azu::Handler::CSRF.configure { |csrf| csrf.strategy = Azu::Handler::CSRF::Strategy::DoubleSubmit } }
    end
  end

  it "lets configure assign the secret after the default instance exists" do
    with_csrf_env({"CRYSTAL_ENV" => "production", "CSRF_SECRET" => nil}) do
      Azu::Handler::CSRF.configure { |csrf| csrf.secret_key = "from-a-vault" }
      Azu::Handler::CSRF.default.secret_key.should eq "from-a-vault"
    end
  end

  it "accepts an explicit secret_key in production" do
    with_csrf_env({"CRYSTAL_ENV" => "production", "CSRF_SECRET" => nil}) do
      Azu::Handler::CSRF.new(secret_key: "explicit").secret_key.should eq "explicit"
    end
  end

  it "reads CSRF_SECRET from the environment, so every instance signs with the same key" do
    with_csrf_env({"CRYSTAL_ENV" => "production", "CSRF_SECRET" => "shared-by-all-instances"}) do
      first = Azu::Handler::CSRF.new
      second = Azu::Handler::CSRF.new
      first.secret_key.should eq "shared-by-all-instances"

      context = csrf_context("GET")
      token = first.token(context)

      post_headers = HTTP::Headers{"Cookie" => "#{Azu::Handler::CSRF::COOKIE_KEY}=#{token}", Azu::Handler::CSRF::HEADER_KEY => token}
      post_context = csrf_context("POST", post_headers)
      second.valid_token?(post_context).should be_true
    end
  end

  it "falls back to a random secret outside production and says so once" do
    with_csrf_env({"CRYSTAL_ENV" => "development", "CSRF_SECRET" => nil}) do
      Log.capture("azu.env") do |logs|
        key = Azu::Handler::CSRF.new.secret_key
        key.size.should be >= 32
        Azu::Handler::CSRF.new.secret_key.should eq key
        logs.check(:warn, /CSRF_SECRET is not set/)
        logs.empty
      end
    end
  end

  it "raises in any strict environment" do
    with_csrf_env({"CRYSTAL_ENV" => "staging", "CSRF_SECRET" => nil}) do
      Azu::Env.strict_environments = ["production", "staging"]
      begin
        expect_raises(Azu::Env::MissingError) { Azu::Handler::CSRF.new }
      ensure
        Azu::Env.strict_environments = nil
      end
    end
  end
end
