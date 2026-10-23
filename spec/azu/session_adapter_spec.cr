require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

# Stands in for `Session::Web`: a session object that answers `[]?`/`[]=` per request,
# without azu's specs depending on the session shard.
class FakeSession
  getter values = Hash(String, String).new
  getter flash = Hash(String, String).new
  property csrf_token : String? = nil
end

private def fake_adapter(session : FakeSession) : Azu::SessionAdapter
  Azu::SessionAdapter.new(
    session: ->(_context : HTTP::Server::Context) { session.values },
    flash: ->(_context : HTTP::Server::Context) { session.flash },
    csrf_token: ->(_context : HTTP::Server::Context) { session.csrf_token },
    store_csrf_token: ->(_context : HTTP::Server::Context, token : String) { session.csrf_token = token; nil },
  )
end

private def with_adapter(adapter : Azu::SessionAdapter?, &)
  previous = Azu.session_adapter
  Azu.session_adapter = adapter
  yield
ensure
  Azu.session_adapter = previous
end

describe "Azu::SessionAdapter" do
  describe "template helper context" do
    it "reads session and flash through the adapter" do
      session = FakeSession.new
      session.values["user"] = "ada"
      session.flash["notice"] = "Saved"
      with_adapter(fake_adapter(session)) do
        context, _ = create_context
        helpers = Azu::Helpers::TemplateContext.new(context)
        helpers.session["user"].should eq("ada")
        helpers.flash["notice"].should eq("Saved")
      end
    end

    it "is empty without an adapter" do
      with_adapter(nil) do
        context, _ = create_context
        helpers = Azu::Helpers::TemplateContext.new(context)
        helpers.session.should be_empty
        helpers.flash.should be_empty
      end
    end

    it "does not trust an unsigned _session or _flash cookie" do
      forged = Base64.strict_encode(%({"user":"admin"}))
      headers = HTTP::Headers{"Cookie" => "_session=#{forged}; _flash=#{forged}"}
      with_adapter(nil) do
        context, _ = create_context("GET", "/", headers)
        helpers = Azu::Helpers::TemplateContext.new(context)
        helpers.session.should be_empty
        helpers.flash.should be_empty
      end
    end

    it "exposes session and flash to templates" do
      session = FakeSession.new
      session.flash["notice"] = "Saved"
      with_adapter(fake_adapter(session)) do
        context, _ = create_context
        vars = Azu::Helpers::TemplateContext.new(context).to_template_vars
        vars["flash"]["notice"].to_s.should eq("Saved")
      end
    end
  end

  describe "CSRF session token store" do
    synchronizer = Azu::Handler::CSRF::Strategy::SynchronizerToken

    it "keeps the synchronizer token in the session, not in a cookie" do
      session = FakeSession.new
      with_adapter(fake_adapter(session)) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        context, _ = create_context
        token = handler.token(context)
        session.csrf_token.should eq(token)
        context.response.cookies.to_a.should be_empty
        handler.token(context).should eq(token)
      end
    end

    it "validates a request that carries the session's token" do
      session = FakeSession.new
      session.csrf_token = "stored-token"
      with_adapter(fake_adapter(session)) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        ok, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "stored-token"})
        handler.valid_token?(ok).should be_true
        bad, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "other"})
        handler.valid_token?(bad).should be_false
      end
    end

    it "ignores a csrf_token cookie when the store is the session" do
      session = FakeSession.new
      with_adapter(fake_adapter(session)) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        headers = HTTP::Headers{"X-CSRF-TOKEN" => "forged", "Cookie" => "csrf_token=forged"}
        context, _ = create_context("POST", "/", headers)
        handler.valid_token?(context).should be_false
      end
    end

    it "refuses to run without a session adapter" do
      with_adapter(nil) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        context, _ = create_context
        expect_raises(Azu::SessionAdapter::NotConfigured) { handler.token(context) }
      end
    end

    it "keeps the cookie store as the default" do
      handler = Azu::Handler::CSRF.new(strategy: synchronizer)
      context, _ = create_context
      token = handler.token(context)
      context.response.cookies["csrf_token"].value.should eq(token)
    end
  end
end
