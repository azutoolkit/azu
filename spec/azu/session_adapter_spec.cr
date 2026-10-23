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

# One FakeSession per value of the X-Session header, like a store keyed by the session cookie.
private def keyed_adapter(sessions : Hash(String, FakeSession)) : Azu::SessionAdapter
  lookup = ->(context : HTTP::Server::Context) { sessions[context.request.headers["X-Session"]] }
  Azu::SessionAdapter.new(
    csrf_token: ->(context : HTTP::Server::Context) { lookup.call(context).csrf_token },
    store_csrf_token: ->(context : HTTP::Server::Context, token : String) { lookup.call(context).csrf_token = token; nil },
  )
end

describe "Azu::SessionAdapter" do
  after_each { Azu.session_adapter = nil }

  it "lives on the configuration, not on the process" do
    other = Azu::Configuration.new
    other.session_adapter.should be_nil
    with_adapter(fake_adapter(FakeSession.new)) { other.session_adapter.should be_nil }
  end

  it "rejects half of the CSRF pair" do
    expect_raises(ArgumentError) { Azu::SessionAdapter.new(csrf_token: ->(_c : HTTP::Server::Context) { nil.as(String?) }) }
    Azu::SessionAdapter.new.csrf?.should be_false
    fake_adapter(FakeSession.new).csrf?.should be_true
  end

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

    it "ignores a forged _session cookie even with an adapter set" do
      session = FakeSession.new
      session.values["user"] = "ada"
      forged = Base64.strict_encode(%({"user":"admin"}))
      with_adapter(fake_adapter(session)) do
        context, _ = create_context("GET", "/", HTTP::Headers{"Cookie" => "_session=#{forged}"})
        Azu::Helpers::TemplateContext.new(context).session["user"].should eq("ada")
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

    it "rejects a token stored in session A on a request of session B" do
      a = FakeSession.new
      b = FakeSession.new
      with_adapter(keyed_adapter({"a" => a, "b" => b})) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        issue, _ = create_context("GET", "/", HTTP::Headers{"X-Session" => "a"})
        token = handler.token(issue)
        b.csrf_token = handler.token(create_context("GET", "/", HTTP::Headers{"X-Session" => "b"})[0])
        handler.valid_token?(create_context("POST", "/", HTTP::Headers{"X-Session" => "a", "X-CSRF-TOKEN" => token})[0]).should be_true
        handler.valid_token?(create_context("POST", "/", HTTP::Headers{"X-Session" => "b", "X-CSRF-TOKEN" => token})[0]).should be_false
      end
    end

    it "treats an empty stored token as none" do
      session = FakeSession.new
      session.csrf_token = ""
      with_adapter(fake_adapter(session)) do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        context, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => ""})
        handler.valid_token?(context).should be_false
        handler.token(context).should_not be_empty
      end
    end

    describe "as a handler" do
      it "passes a valid token, refuses a wrong one with 403" do
        session = FakeSession.new
        session.csrf_token = "good"
        with_adapter(fake_adapter(session)) do
          handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
          handler.next = ->(c : HTTP::Server::Context) { c.response.print "OK" }
          ok, io = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "good"})
          handler.call(ok)
          get_response_body(ok, io).should eq("OK")
          bad, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "bad"})
          handler.call(bad)
          bad.response.status_code.should eq(403)
        end
      end

      it "answers 403, not 500, without an adapter or when the session lookup raises" do
        handler = Azu::Handler::CSRF.new(strategy: synchronizer, token_store: Azu::Handler::CSRF::SessionTokenStore.new)
        handler.next = ->(c : HTTP::Server::Context) { c.response.print "OK" }
        with_adapter(nil) do
          context, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "x"})
          handler.call(context)
          context.response.status_code.should eq(403)
        end
        raising = Azu::SessionAdapter.new(
          csrf_token: ->(_c : HTTP::Server::Context) { raise "no session for this request"; nil.as(String?) },
          store_csrf_token: ->(_c : HTTP::Server::Context, _t : String) { nil },
        )
        with_adapter(raising) do
          context, _ = create_context("POST", "/", HTTP::Headers{"X-CSRF-TOKEN" => "x"})
          handler.call(context)
          context.response.status_code.should eq(403)
        end
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
