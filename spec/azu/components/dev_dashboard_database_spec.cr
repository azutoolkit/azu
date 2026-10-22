require "../../spec_helper"

alias DatabaseStats = Azu::Components::Dashboard::DatabaseData::DatabaseStats
alias SlowQuery = Azu::Components::Dashboard::DatabaseData::SlowQuery
alias QueryPattern = Azu::Components::Dashboard::DatabaseData::QueryPattern
alias NPlusOneIssue = Azu::Components::Dashboard::DatabaseData::NPlusOneIssue

# A provider whose database numbers are supplied by the spec, since the CQL monitor is not
# part of azu's own dependencies.
private class FakeDatabaseProvider < Azu::Components::DashboardDataProvider
  property db_stats = Azu::Components::Dashboard::DatabaseData::INACTIVE
  property db_slow = [] of SlowQuery
  property db_patterns = [] of QueryPattern
  property db_issues = [] of NPlusOneIssue

  def database_stats : DatabaseStats
    db_stats
  end

  def slow_queries(limit : Int32 = 20) : Array(SlowQuery)
    db_slow
  end

  def query_patterns(limit : Int32 = 15) : Array(QueryPattern)
    db_patterns
  end

  def n_plus_one_issues : Array(NPlusOneIssue)
    db_issues
  end
end

# The dashboard with the provider replaced by the spec's.
private class DatabaseDashboard < Azu::Components::DevDashboardComponent
  def initialize(@fake : FakeDatabaseProvider)
    super(Azu::PerformanceMetrics.new)
    @provider = @fake
  end
end

private def database_page(provider : FakeDatabaseProvider) : String
  DatabaseDashboard.new(provider).render
end

private def fake_provider : FakeDatabaseProvider
  FakeDatabaseProvider.new(Azu::PerformanceMetrics.new, Time.utc, Log.for("spec"))
end

describe "Dev dashboard Database tab" do
  describe DatabaseStats do
    it "is fully healthy without slow queries, N+1 patterns or latency" do
      DatabaseStats.new(true, 10_i64, 2, 5.0, 1.0, 9.0, 0, 0, 0, 0, 0).health.should eq 100
    end

    it "loses points for slow queries, N+1 patterns and a high average, each capped" do
      stats = DatabaseStats.new(true, 500_i64, 9, 300.0, 1.0, 900.0, 40, 5, 20, 3, 4)

      stats.health.should eq(100 - 30 - 25 - 4) # slow cap 30, N+1 cap 25, (300 - 100) / 50 = 4
    end

    it "never goes below zero" do
      DatabaseStats.new(true, 1_i64, 1, 5000.0, 1.0, 9000.0, 999, 999, 999, 9, 9).health.should be >= 0
    end
  end

  it "collapses into one explanatory card when CQL monitoring is not active" do
    html = database_page(fake_provider)

    html.should contain("CQL performance monitoring is not active")
    html.should_not contain("Slow queries")
  end

  it "shows the counters, slow queries, patterns and N+1 issues of an active monitor" do
    provider = fake_provider
    provider.db_stats = DatabaseStats.new(true, 33_i64, 4, 6.7, 1.0, 180.1, 1, 0, 1, 0, 0)
    provider.db_slow = [SlowQuery.new("SELECT * FROM posts", 180.1, 12_i64, Time.utc)]
    provider.db_patterns = [QueryPattern.new("SELECT * FROM comments WHERE post_id = ?", 30, 1.07, 100.0)]
    provider.db_issues = [NPlusOneIssue.new("high", "Query repeated 10 times")]

    html = database_page(provider)

    html.should contain("33")
    html.should contain("4 unique patterns")
    html.should contain("180.1ms")
    html.should contain("12 rows")
    html.should contain("SELECT * FROM comments WHERE post_id = ?")
    html.should contain("Query repeated 10 times")
  end

  it "escapes SQL, which carries user-controlled values" do
    provider = fake_provider
    provider.db_stats = DatabaseStats.new(true, 1_i64, 1, 1.0, 1.0, 1.0, 0, 0, 0, 0, 0)
    hostile = %(SELECT '"><script>alert(1)</script>' FROM t)
    provider.db_slow = [SlowQuery.new(hostile, 1.0, 0_i64, Time.utc)]
    provider.db_patterns = [QueryPattern.new(hostile, 1, 1.0, 100.0)]

    html = database_page(provider)

    html.should_not contain(%(<script>alert(1)</script>))
    html.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
  end

  it "says so when an active monitor has nothing to report yet" do
    provider = fake_provider
    provider.db_stats = DatabaseStats.new(true, 0_i64, 0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 0)

    html = database_page(provider)

    html.should contain("No slow queries")
    html.should contain("No query patterns recorded")
    html.should contain("No N+1 patterns detected")
  end
end
