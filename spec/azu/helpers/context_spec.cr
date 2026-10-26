require "../../spec_helper"
require "../../support/template_helpers"

module TemplateContextSpec
  # A page an endpoint renders with `view`, which hands it the request.
  struct Page
    include Azu::Templates::Renderable

    getter context : HTTP::Server::Context

    def initialize(@template : String, @context : HTTP::Server::Context, @data = {} of String => String)
    end

    def render : String
      view @template, @data
    end
  end

  def self.request(headers = HTTP::Headers.new) : HTTP::Server::Context
    HTTP::Server::Context.new(HTTP::Request.new("GET", "/items", headers), HTTP::Server::Response.new(IO::Memory.new))
  end

  def self.csrf_cookie(context : HTTP::Server::Context) : String?
    context.response.cookies[Azu::Handler::CSRF.cookie_name]?.try(&.value)
  end
end

describe Azu::Helpers::TemplateContext do
  describe "request variables in a view" do
    {
      "a for loop"       => { {"page.jinja" => "{% for i in [1, 2] %}{{ method }}{% endfor %}"}, "GETGET" },
      "an include"       => { {"page.jinja" => %({% include "part.jinja" %}), "part.jinja" => "{{ method }}"}, "GET" },
      "a macro"          => { {"page.jinja" => "{% macro m() %}{{ method }}{% endmacro %}{{ m() }}"}, "GET" },
      "an extends block" => { {"page.jinja" => %({% extends "layout.jinja" %}{% block body %}{{ method }}{% endblock %}),
                               "layout.jinja" => "<{% block body %}{% endblock %}>"}, "<GET>" },
    }.each do |construct, (files, expected)|
      it "are read from #{construct}" do
        with_compiled_templates(files) do
          TemplateContextSpec::Page.new("page.jinja", TemplateContextSpec.request).render.should eq expected
        end
      end
    end

    it "give way to the view's data of the same name" do
      with_compiled_templates({"page.jinja" => "{{ method }}"}) do
        TemplateContextSpec::Page.new("page.jinja", TemplateContextSpec.request, {"method" => "mine"}).render.should eq "mine"
      end
    end

    it "hide a global of the same name" do
      with_compiled_templates({"page.jinja" => "{{ referer }}"}) do |config|
        config.templates.crinja.global_context["referer"] = "global"
        context = TemplateContextSpec.request(HTTP::Headers{"Referer" => "https://example.com/from"})

        TemplateContextSpec::Page.new("page.jinja", context).render.should eq "https://example.com/from"
      end
    end
  end

  describe "CSRF variables in a view" do
    Azu::Handler::CSRF::Strategy.each do |strategy|
      it "carry the token the CSRF cookie holds (#{strategy})" do
        previous = Azu::Handler::CSRF.strategy
        Azu::Handler::CSRF.strategy = strategy
        begin
          with_compiled_templates({"csrf.jinja" => "{{ csrf_token }}|{{ csrf_tag }}|{{ csrf_metatag }}"}) do
            context = TemplateContextSpec.request
            token, tag, metatag = TemplateContextSpec::Page.new("csrf.jinja", context).render.split('|')
            param = Azu::Handler::CSRF.param_name

            tag.should eq %(<input type="hidden" name="#{param}" value="#{token}" />)
            metatag.should eq %(<meta name="#{param}" content="#{token}" />)
            TemplateContextSpec.csrf_cookie(context).should eq token
          end
        ensure
          Azu::Handler::CSRF.strategy = previous
        end
      end
    end

    it "set the CSRF cookie when the template prints no token" do
      with_compiled_templates({"plain.jinja" => "<h1>{{ title }}</h1>"}) do
        context = TemplateContextSpec.request

        TemplateContextSpec::Page.new("plain.jinja", context, {"title" => "Items"}).render.should eq "<h1>Items</h1>"
        TemplateContextSpec.csrf_cookie(context).should_not be_nil
      end
    end

    it "reuse the token an earlier view of the same request issued" do
      with_compiled_templates({"token.jinja" => "{{ csrf_token }}"}) do
        context = TemplateContextSpec.request
        # A layout and a partial, each rendered with `view`: one cookie, so both pages' tokens stay valid
        first = TemplateContextSpec::Page.new("token.jinja", context).render
        second = TemplateContextSpec::Page.new("token.jinja", context).render

        second.should eq first
        TemplateContextSpec.csrf_cookie(context).should eq first
      end
    end
  end
end
