require "../../../spec_helper"

describe "Date Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::DateHelpers.register
  end

  describe "time_ago filter" do
    it "returns 'just now' for recent times" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "just now"
    end

    it "returns minutes ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 5.minutes

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "5 minutes ago"
    end

    it "returns singular minute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 1.minute

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "1 minute ago"
    end

    it "returns hours ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 3.hours

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "3 hours ago"
    end

    it "returns days ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 2.days

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "2 days ago"
    end

    it "returns weeks ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 14.days

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "2 weeks ago"
    end

    it "returns months ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 60.days

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "2 months ago"
    end

    it "returns years ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 400.days

      template = crinja.from_string("{{ time | time_ago }}")
      result = template.render

      result.should eq "1 year ago"
    end
  end

  describe "date_format filter" do
    it "formats date with custom pattern" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["date"] = Time.utc(2024, 1, 15, 10, 30, 0)

      template = crinja.from_string("{{ date | date_format('%Y-%m-%d') }}")
      result = template.render

      result.should eq "2024-01-15"
    end

    it "formats with time" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["date"] = Time.utc(2024, 1, 15, 10, 30, 0)

      template = crinja.from_string("{{ date | date_format('%Y-%m-%d %H:%M') }}")
      result = template.render

      result.should eq "2024-01-15 10:30"
    end

    it "uses default format when none specified" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["date"] = Time.utc(2024, 1, 15)

      template = crinja.from_string("{{ date | date_format }}")
      result = template.render

      result.should contain "2024"
      result.should contain "15"
    end
  end

  describe "relative_time filter" do
    it "returns 'in X minutes' for future times" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc + 5.minutes + 30.seconds

      template = crinja.from_string("{{ time | relative_time }}")
      result = template.render

      result.should match /in \d+ minutes/
    end

    it "returns 'in X hours' for future hours" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc + 3.hours + 30.minutes

      template = crinja.from_string("{{ time | relative_time }}")
      result = template.render

      result.should match /in \d+ hours/
    end

    it "returns 'in X days' for future days" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc + 3.days + 12.hours

      template = crinja.from_string("{{ time | relative_time }}")
      result = template.render

      result.should match /in \d+ days/
    end

    it "returns past times with ago" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc - 5.minutes

      template = crinja.from_string("{{ time | relative_time }}")
      result = template.render

      result.should eq "5 minutes ago"
    end
  end

  describe "time_tag function" do
    it "generates time element" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc(2024, 1, 15, 10, 30, 0)

      template = crinja.from_string("{{ time_tag(time) }}")
      result = template.render

      result.should contain "<time"
      result.should contain "datetime="
      result.should contain "</time>"
    end

    it "supports custom format" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc(2024, 1, 15)

      template = crinja.from_string("{{ time_tag(time, format='%Y-%m-%d') }}")
      result = template.render

      result.should contain ">2024-01-15</time>"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.context["time"] = Time.utc(2024, 1, 15)

      template = crinja.from_string("{{ time_tag(time, class='timestamp') }}")
      result = template.render

      result.should contain "class=\"timestamp\""
    end
  end

  describe "distance_of_time filter" do
    it "returns human readable duration in seconds" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 45 | distance_of_time }}")
      result = template.render

      result.should eq "45 seconds"
    end

    it "returns human readable duration in minutes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 150 | distance_of_time }}")
      result = template.render

      result.should eq "2 minutes"
    end

    it "returns human readable duration in hours" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 7200 | distance_of_time }}")
      result = template.render

      result.should eq "2 hours"
    end
  end
end
