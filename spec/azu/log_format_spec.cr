require "../spec_helper"

describe Azu::LogFormat do
  describe "SQL formatting" do
    it "formats SQL query with colorization" do
      query = "SELECT * FROM users WHERE id = 123"
      formatted = Azu::SQL.colorize_query(query)

      # Should contain the query content
      formatted.should contain("SELECT")
      formatted.should contain("FROM")
      formatted.should contain("WHERE")
      formatted.should contain("123")
    end

    it "handles SQL keywords" do
      query = "SELECT id, name FROM users WHERE active = true ORDER BY created_at DESC"
      formatted = Azu::SQL.colorize_query(query)

      # Should contain all SQL keywords
      formatted.should contain("SELECT")
      formatted.should contain("FROM")
      formatted.should contain("WHERE")
      formatted.should contain("ORDER")
      formatted.should contain("BY")
      formatted.should contain("DESC")
    end

    it "handles numbers in queries" do
      query = "SELECT * FROM products WHERE price > 100 AND quantity < 50"
      formatted = Azu::SQL.colorize_query(query)

      # Should contain the numbers
      formatted.should contain("100")
      formatted.should contain("50")
    end

    it "handles comments in SQL" do
      query = "SELECT * FROM users -- This is a comment"
      formatted = Azu::SQL.colorize_query(query)

      # Should contain the comment
      formatted.should contain("-- This is a comment")
    end

    it "handles complex SQL with joins" do
      query = "SELECT u.name, p.title FROM users u LEFT JOIN posts p ON u.id = p.user_id WHERE u.active = true"
      formatted = Azu::SQL.colorize_query(query)

      # Should contain all SQL keywords
      formatted.should contain("SELECT")
      formatted.should contain("FROM")
      formatted.should contain("LEFT")
      formatted.should contain("JOIN")
      formatted.should contain("ON")
      formatted.should contain("WHERE")
    end
  end

  describe "SQL formatter" do
    it "creates SQL formatter with required parameters" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::SQL::Formatter.new(entry, io)
      formatter.should be_a(Log::StaticFormatter)
    end

    it "has orange_red color property" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::SQL::Formatter.new(entry, io)
      formatter.orange_red.should be_a(Colorize::ColorRGB)
    end
  end

  describe "time display" do
    it "displays minutes and seconds for long durations" do
      time = 125.5 # 2 minutes 5 seconds
      result = Azu::SQL.display_mn_sec(time)

      result.should eq("02mn05s")
    end

    it "displays time in seconds for medium durations" do
      time = 45.67
      result = Azu::SQL.display_time(time)

      result.should eq("45.67s")
    end

    it "displays time in milliseconds for short durations" do
      time = 0.5
      result = Azu::SQL.display_time(time)

      result.should eq("500ms")
    end

    it "displays time in microseconds for very short durations" do
      time = 0.0005
      result = Azu::SQL.display_time(time)

      result.should eq("500µs")
    end

    it "handles zero time" do
      time = 0.0
      result = Azu::SQL.display_time(time)

      result.should eq("0µs")
    end

    it "handles very large times" do
      time = 3661.0 # 1 hour 1 minute 1 second
      result = Azu::SQL.display_mn_sec(time)

      result.should eq("61mn01s")
    end
  end

  describe "LogFormat" do
    it "creates log format instance with required parameters" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.should be_a(Log::StaticFormatter)
    end

    it "has orange_red color property" do
      entry = Log::Entry.new("test", Log::Severity::Info, "test", Log::Metadata.new, nil)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.orange_red.should be_a(Colorize::ColorRGB)
    end
  end

  describe "SQL colorization settings" do
    it "has colorize property" do
      # Should be a boolean property
      Azu::SQL.colorize.should be_a(Bool)
    end

    it "can be disabled" do
      original_setting = Azu::SQL.colorize
      Azu::SQL.colorize = false

      query = "SELECT * FROM users"
      formatted = Azu::SQL.colorize_query(query)

      # When disabled, should return original query
      formatted.should eq(query)

      # Restore original setting
      Azu::SQL.colorize = original_setting
    end
  end

  describe "SQL keywords" do
    it "recognizes common SQL keywords" do
      keywords = %w(SELECT INSERT UPDATE DELETE FROM WHERE AND OR ORDER BY)

      keywords.each do |keyword|
        query = "#{keyword} test"
        formatted = Azu::SQL.colorize_query(query)

        # Should contain the keyword
        formatted.should contain(keyword)
      end
    end

    it "handles case insensitive keywords" do
      query = "select * from users where id = 1"
      formatted = Azu::SQL.colorize_query(query)

      # Should handle lowercase keywords
      formatted.should contain("select")
      formatted.should contain("from")
      formatted.should contain("where")
    end
  end

  describe "edge cases" do
    it "handles empty query" do
      query = ""
      formatted = Azu::SQL.colorize_query(query)

      formatted.should eq("")
    end

    it "handles query with only whitespace" do
      query = "   "
      formatted = Azu::SQL.colorize_query(query)

      formatted.should eq("   ")
    end

    it "handles query with special characters" do
      query = "SELECT * FROM `users` WHERE `name` = 'John\\'s'"
      formatted = Azu::SQL.colorize_query(query)

      # Should handle backticks and escaped quotes
      formatted.should contain("SELECT")
      formatted.should contain("FROM")
      formatted.should contain("WHERE")
    end

    it "handles very long queries" do
      query = "SELECT " + "id, " * 100 + "name FROM users"
      formatted = Azu::SQL.colorize_query(query)

      # Should not crash and should contain the query
      formatted.should contain("SELECT")
      formatted.should contain("FROM")
    end
  end

  describe "performance" do
    it "handles repeated calls efficiently" do
      query = "SELECT * FROM users WHERE active = true"

      # Multiple calls should work without issues
      10.times do
        formatted = Azu::SQL.colorize_query(query)
        formatted.should contain("SELECT")
        formatted.should contain("FROM")
        formatted.should contain("WHERE")
      end
    end
  end
end
