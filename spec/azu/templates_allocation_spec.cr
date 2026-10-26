require "../spec_helper"
require "../../benchmark/micro/harness"
require "../support/template_helpers"

module TemplatesAllocationSpec
  VARIABLES_SOURCE = "{{ a }}{{ b }}{{ c }}{{ d }}{{ e }}"
  PLAIN_SOURCE     = "<h1>{{ title }}</h1>"

  # A page rendered with `view`, as an endpoint's response renders it.
  struct VariablesPage
    include Azu::Templates::Renderable

    def initialize(@data : Hash(String, Crinja::Value), @template = "variables.jinja")
    end

    def render : String
      view @template, @data
    end
  end

  # A page rendered with `view` from an endpoint, which hands it the request.
  struct RequestPage
    include Azu::Templates::Renderable

    getter context : HTTP::Server::Context

    def initialize(@template : String, @context : HTTP::Server::Context, @data = {"title" => Crinja::Value.new("Items")})
    end

    def render : String
      view @template, @data
    end
  end

  def self.request_context : HTTP::Server::Context
    HTTP::Server::Context.new(HTTP::Request.new("GET", "/items"), HTTP::Server::Response.new(IO::Memory.new))
  end

  # What `view` computed per render with a request before: query and cookies parsed, every variable (one token now,
  # which csrf_tag and csrf_metatag reuse; each issued its own before).
  def self.every_request_variable(context : HTTP::Server::Context) : Hash(String, Crinja::Value)
    request, csrf = Azu::Helpers::TemplateContext.new(context), Azu::Handler::CSRF
    request.params
    request.cookies
    {request.current_path, request.current_url, csrf.token(context), csrf.tag(context), csrf.metatag(context), request.flash,
     request.method, request.secure?, request.ajax?, request.referer || "", request.client_ip || "", request.accept_language || "en",
    }.map_with_index { |value, i| {Azu::Helpers::TemplateContext::VARIABLES[i], Crinja::Value.new(value)} }.to_h
  end
end

describe "view allocations" do
  {% if flag?(:preview_mt) %}
    # GC.stats.total_bytes counts every thread
    pending "hands its variables to the render without copying them"
  {% else %}
    it "hands its variables to the render without copying them" do
      data = {"a" => Crinja::Value.new(1), "b" => Crinja::Value.new("two"), "c" => Crinja::Value.new(3), "d" => Crinja::Value.new(4), "e" => Crinja::Value.new(5)}
      with_preloaded_templates({"variables.jinja" => TemplatesAllocationSpec::VARIABLES_SOURCE}) do |config|
        page = TemplatesAllocationSpec::VariablesPage.new(data)
        template = config.templates.load("variables.jinja")
        page.render.should eq "1two345"

        through_view = HotPath.bytes_per_call { page.render }
        # What a render needs at least: its variables in a context below the environment's, then the template
        in_place = HotPath.bytes_per_call do
          context = Crinja::Context.new(config.templates.crinja.context)
          data.each { |key, value| context[key] = value }
          template.render(context)
        end

        # Only view's own hash (~64 B) and the scope's request field differ; copying it for Crinja cost ~1.4 KB here
        (through_view - in_place).should be <= 96
      end
    end
  {% end %}
end

describe "view with a request" do
  {% if flag?(:preview_mt) %}
    pending "costs a template that reads no request variable only the token its cookie needs"
  {% else %}
    it "costs a template that reads no request variable only the token its cookie needs" do
      with_preloaded_templates({"plain.jinja" => TemplatesAllocationSpec::PLAIN_SOURCE}) do
        context = TemplatesAllocationSpec.request_context
        with_request = TemplatesAllocationSpec::RequestPage.new("plain.jinja", context)
        without_request = TemplatesAllocationSpec::VariablesPage.new({"title" => Crinja::Value.new("Items")}, "plain.jinja")

        request_cost = HotPath.bytes_per_call { context.response.reset; with_request.render } -
                       HotPath.bytes_per_call { context.response.reset; without_request.render }
        every_variable = HotPath.bytes_per_call { context.response.reset; TemplatesAllocationSpec.every_request_variable(context) }
        one_token = HotPath.bytes_per_call { context.response.reset; Azu::Handler::CSRF.token(context) }

        # Left: the one token that sets the cookie and the TemplateContext object. Measured 2,907 B below every_variable,
        # which leaves out the old merge of the variables into the render's hash (~1 KB more); csrf_tag and csrf_metatag
        # there reuse the response's token now, where each issued its own before (another ~1 KB)
        (request_cost - one_token).should be <= 128
        (every_variable - request_cost).should be >= 2600
      end
    end
  {% end %}
end
