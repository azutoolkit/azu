require "../../spec_helper"
require "../../../src/azu/cql"

# Including Azu makes its CQL bridge visible to application code and ORM macros.
module CQLNamespaceSpec
  include Azu

  alias Schema = CQL::Schema
  alias Model = CQL::ActiveRecord::Model
end

describe "Azu::CQL namespace compatibility" do
  it "preserves public ORM types inside applications including Azu" do
    CQLNamespaceSpec::Schema.should eq(::CQL::Schema)
    CQLNamespaceSpec::Model.should eq(::CQL::ActiveRecord::Model)
  end

  it "does not export CQL's private migration implementation" do
    {{ Azu::CQL.has_constant?("MigrationLock") }}.should be_false
  end

  {% for name in ::CQL.constants %}
    {% type = ::CQL.constant(name) %}
    {% if type.is_a?(TypeNode) && type.private? %}
      it "does not export private CQL type {{name.id}}" do
        {{ Azu::CQL.has_constant?(name) }}.should be_false
      end
    {% end %}
  {% end %}
end
