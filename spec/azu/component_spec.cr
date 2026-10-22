require "../spec_helper"

class GreetingComponent
  include Azu::Component

  def initialize(@name : String)
  end

  def content
    div(class: "greeting") do
      h1 "Hello #{@name}"
      raw "<hr>"
    end
  end
end

describe Azu::Component do
  it "renders the markup of #content without any live wrapper" do
    GreetingComponent.new("Azu").render.should eq "<div class='greeting'><h1>Hello Azu</h1><hr></div>"
  end

  it "escapes interpolated values" do
    GreetingComponent.new("<script>").render.should contain "Hello &lt;script&gt;"
  end

  it "renders the same output every time" do
    component = GreetingComponent.new("Azu")

    component.render.should eq component.render
  end

  it "is a Markup" do
    GreetingComponent.new("x").should be_a(Azu::Markup)
  end
end
