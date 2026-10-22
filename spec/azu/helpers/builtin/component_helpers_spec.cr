require "../../../spec_helper"

describe "Component Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::ComponentHelpers.register
  end

  it "no longer registers the retired Spark client helpers" do
    Azu::Helpers::Registry.has_function?(:spark_tag).should be_false
    {:live_click, :live_change, :live_input, :live_value}.each do |name|
      Azu::Helpers::Registry.has_filter?(name).should be_false
    end
  end

  it "keeps the component_id filter" do
    Azu::Helpers::Registry.has_filter?(:component_id).should be_true
  end
end
