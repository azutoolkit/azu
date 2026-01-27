require "../../../spec_helper"

describe "Number Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::NumberHelpers.register
  end

  describe "currency filter" do
    it "formats number as currency with default symbol" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234.5 | currency }}")
      result = template.render

      result.should eq "$1,234.50"
    end

    it "supports custom currency symbol" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234.5 | currency(symbol='€') }}")
      result = template.render

      result.should eq "€1,234.50"
    end

    it "supports custom precision" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234.567 | currency(precision=3) }}")
      result = template.render

      result.should eq "$1,234.567"
    end

    it "handles negative numbers" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ -1234.5 | currency }}")
      result = template.render

      result.should eq "-$1,234.50"
    end

    it "handles zero" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 0 | currency }}")
      result = template.render

      result.should eq "$0.00"
    end
  end

  describe "number_with_delimiter filter" do
    it "adds thousands separator" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567 | number_with_delimiter }}")
      result = template.render

      # Crinja treats integers as floats, so .0 is appended
      result.should contain "1,234,567"
    end

    it "supports custom delimiter" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567 | number_with_delimiter(delimiter='.') }}")
      result = template.render

      result.should contain "1.234.567"
    end

    it "preserves decimal places" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567.89 | number_with_delimiter }}")
      result = template.render

      result.should eq "1,234,567.89"
    end

    it "handles small numbers" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 123 | number_with_delimiter }}")
      result = template.render

      result.should contain "123"
    end
  end

  describe "percentage filter" do
    it "formats decimal as percentage" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 0.756 | percentage }}")
      result = template.render

      result.should eq "76%"
    end

    it "supports precision" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 0.756 | percentage(precision=1) }}")
      result = template.render

      result.should eq "75.6%"
    end

    it "handles values over 1" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1.5 | percentage }}")
      result = template.render

      result.should eq "150%"
    end

    it "handles zero" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 0 | percentage }}")
      result = template.render

      result.should eq "0%"
    end
  end

  describe "filesize filter" do
    it "formats bytes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 500 | filesize }}")
      result = template.render

      result.should eq "500 B"
    end

    it "formats kilobytes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1024 | filesize }}")
      result = template.render

      result.should eq "1.0 KB"
    end

    it "formats megabytes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1048576 | filesize }}")
      result = template.render

      result.should eq "1.0 MB"
    end

    it "formats gigabytes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1073741824 | filesize }}")
      result = template.render

      result.should eq "1.0 GB"
    end

    it "supports custom precision" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1536 | filesize(precision=2) }}")
      result = template.render

      result.should eq "1.50 KB"
    end
  end

  describe "ordinal filter" do
    it "returns 1st for 1" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1 | ordinal }}")
      result = template.render

      result.should eq "1st"
    end

    it "returns 2nd for 2" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 2 | ordinal }}")
      result = template.render

      result.should eq "2nd"
    end

    it "returns 3rd for 3" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 3 | ordinal }}")
      result = template.render

      result.should eq "3rd"
    end

    it "returns 4th for 4" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 4 | ordinal }}")
      result = template.render

      result.should eq "4th"
    end

    it "handles 11th, 12th, 13th correctly" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      crinja.from_string("{{ 11 | ordinal }}").render.should eq "11th"
      crinja.from_string("{{ 12 | ordinal }}").render.should eq "12th"
      crinja.from_string("{{ 13 | ordinal }}").render.should eq "13th"
    end

    it "handles 21st, 22nd, 23rd correctly" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      crinja.from_string("{{ 21 | ordinal }}").render.should eq "21st"
      crinja.from_string("{{ 22 | ordinal }}").render.should eq "22nd"
      crinja.from_string("{{ 23 | ordinal }}").render.should eq "23rd"
    end
  end

  describe "number_to_human filter" do
    it "formats thousands" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234 | number_to_human }}")
      result = template.render

      result.should eq "1.2 thousand"
    end

    it "formats millions" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567 | number_to_human }}")
      result = template.render

      result.should eq "1.2 million"
    end

    it "formats billions" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567890 | number_to_human }}")
      result = template.render

      result.should eq "1.2 billion"
    end

    it "returns small numbers as-is" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 999 | number_to_human }}")
      result = template.render

      result.should contain "999"
    end

    it "supports custom precision" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 1234567 | number_to_human(precision=2) }}")
      result = template.render

      result.should eq "1.23 million"
    end
  end
end
