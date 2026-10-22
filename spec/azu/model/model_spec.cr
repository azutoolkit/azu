require "../../spec_helper"
require "../../support/postgres"
require "../../../src/azu/model"

# Models are global in Crystal, so the specs use their own namespace and table names.
module ModelSpec
  class User < Azu::Model
    table :model_spec_users
    column id : Int64, primary_key: true
    column email : String, validate: :email, unique: true
    column name : String
    column role : String = "member"
    column bio : String?
    timestamps

    validates :name, presence: true, length: 2..80

    has_many posts : ModelSpec::Post, foreign_key: :user_id
    has_one profile : ModelSpec::Profile, foreign_key: :user_id

    scope :admins, -> { where(role: "admin") }
    scope :recent, -> { order(id: :desc) }
  end

  class Post < Azu::Model
    table :model_spec_posts
    column id : Int64, primary_key: true
    column user_id : Int64
    column title : String
    belongs_to user : ModelSpec::User
  end

  class Profile < Azu::Model
    table :model_spec_profiles
    column id : Int64, primary_key: true
    column user_id : Int64
    column website : String?
    belongs_to user : ModelSpec::User
  end

  def self.reset_tables
    schema = Azu::Database.schema
    %w(model_spec_profiles model_spec_posts model_spec_users).each { |table| schema.exec("DROP TABLE IF EXISTS #{table}") }
    schema.exec("CREATE TABLE model_spec_users (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, name TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'member', bio TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ)")
    schema.exec("CREATE TABLE model_spec_posts (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES model_spec_users(id), title TEXT NOT NULL)")
    schema.exec("CREATE TABLE model_spec_profiles (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES model_spec_users(id), website TEXT)")
  end

  def self.seed(users = 3, posts_per_user = 2)
    users.times do |i|
      user = User.create!(email: "user#{i}@example.com", name: "User #{i}", role: i == 0 ? "admin" : "member")
      posts_per_user.times { |j| Post.create!(user_id: user.id.not_nil!, title: "Post #{i}-#{j}") }
      Profile.create!(user_id: user.id.not_nil!, website: "https://u#{i}.example.com")
    end
  end

  # Counts SQL statements issued while the block runs (via the dev dashboard store).
  def self.queries_during(&) : Int64
    before = Azu::QueryStore.instance.last_id
    yield
    Azu::QueryStore.instance.last_id - before
  end
end

describe Azu::Model do
  before_all do
    if PostgresSpec.available?
      Azu::CONFIG.database.url = PostgresSpec.url
      Azu::Database.schema = nil
      Azu::Database.schema
      Azu::CQL::Instrumentor.install
    end
  end

  before_each do
    if PostgresSpec.available?
      ModelSpec.reset_tables
      Azu::CONFIG.database.n_plus_one = Azu::DatabaseConfiguration::NPlusOne::Off
    end
  end

  describe "setup" do
    it "connects lazily from the configured URL and reports health" do
      PostgresSpec.require!
      Azu::Database.connected?.should be_true
      Azu::Database.healthy?.should be_true
      Azu::Database.pool.should_not be_nil
    end

    it "learns table columns from model declarations" do
      PostgresSpec.require!
      columns = Azu::Database.schema.tables[:model_spec_users].columns.keys
      columns.should contain :email
      columns.should contain :created_at
      ModelSpec::User.table.should eq :model_spec_users
    end

    it "raises a helpful error when the database is unreachable" do
      PostgresSpec.require!
      original = Azu::CONFIG.database.url
      Azu::Database.schema = nil
      Azu::CONFIG.database.url = "postgres://postgres:secret@127.0.0.1:1/nope"
      begin
        error = expect_raises(Azu::Database::ConnectionError) { Azu::Database.schema }
        error.message.to_s.should contain "Cannot connect to the database"
        error.message.to_s.should contain "azu db:create"
        error.message.to_s.should_not contain "secret"
      ensure
        Azu::CONFIG.database.url = original
        Azu::Database.schema = nil
        Azu::Database.schema
      end
    end
  end

  describe "CRUD" do
    it "creates, reads, updates and deletes" do
      PostgresSpec.require!
      user = ModelSpec::User.create!(email: "ada@example.com", name: "Ada")
      user.id.should_not be_nil
      user.role.should eq "member"
      user.created_at.should_not be_nil

      found = ModelSpec::User.find!(user.id.not_nil!)
      found.name.should eq "Ada"

      found.name = "Ada Lovelace"
      found.save!
      ModelSpec::User.find!(user.id.not_nil!).name.should eq "Ada Lovelace"

      ModelSpec::User.count.should eq 1
      found.delete!
      ModelSpec::User.count.should eq 0
    end

    it "stores nullable columns" do
      PostgresSpec.require!
      user = ModelSpec::User.create!(email: "n@example.com", name: "Nullable")
      ModelSpec::User.find!(user.id.not_nil!).bio.should be_nil
      user.bio = "hello"
      user.save!
      ModelSpec::User.find!(user.id.not_nil!).bio.should eq "hello"
    end

    it "scopes chain" do
      PostgresSpec.require!
      ModelSpec.seed
      ModelSpec::User.admins.all.map(&.email).should eq ["user0@example.com"]
      ModelSpec::User.recent.to_a.map(&.name).should eq ["User 2", "User 1", "User 0"]
    end
  end

  describe "validations" do
    it "rejects blank and badly formatted fields with friendly messages" do
      PostgresSpec.require!
      user = ModelSpec::User.new
      user.email = "not-an-email"
      user.name = ""
      user.valid?.should be_false
      messages = user.errors.map(&.message)
      messages.should contain "email must be a valid email"
      messages.should contain "name must be present"
    end

    it "raises from create! and writes nothing" do
      PostgresSpec.require!
      expect_raises(CQL::ActiveRecord::Validations::ValidationError) do
        ModelSpec::User.create!(email: "bad", name: "A")
      end
      ModelSpec::User.count.should eq 0
    end

    it "enforces uniqueness but allows updating the same record" do
      PostgresSpec.require!
      user = ModelSpec::User.create!(email: "dup@example.com", name: "First")
      error = expect_raises(CQL::ActiveRecord::Validations::ValidationError) do
        ModelSpec::User.create!(email: "dup@example.com", name: "Second")
      end
      error.message.to_s.should contain "email has already been taken"

      user.name = "Renamed"
      user.save!
      ModelSpec::User.find!(user.id.not_nil!).name.should eq "Renamed"
    end
  end

  describe "transactions" do
    it "commits on success and rolls back on DB::Rollback or exceptions" do
      PostgresSpec.require!
      ModelSpec::User.transaction { |_tx| ModelSpec::User.create!(email: "ok@example.com", name: "Committed") }
      ModelSpec::User.count.should eq 1

      ModelSpec::User.transaction do |_tx|
        ModelSpec::User.create!(email: "rb@example.com", name: "RolledBack")
        raise DB::Rollback.new
      end
      ModelSpec::User.count.should eq 1

      expect_raises(Exception, "boom") do
        ModelSpec::User.transaction do |_tx|
          ModelSpec::User.create!(email: "boom@example.com", name: "Boom")
          raise "boom"
        end
      end
      ModelSpec::User.count.should eq 1
    end

    it "accepts the transaction explicitly: create!(tx, ...)" do
      PostgresSpec.require!
      ModelSpec::User.transaction do |tx|
        user = ModelSpec::User.create!(tx, email: "tx@example.com", name: "Tx")
        ModelSpec::Profile.create!(tx, user_id: user.id.not_nil!, website: "https://tx.example.com")
      end
      ModelSpec::User.count.should eq 1
      ModelSpec::Profile.count.should eq 1
    end
  end

  describe "associations and preload" do
    it "preloads has_many, has_one and belongs_to in one extra query each" do
      PostgresSpec.require!
      ModelSpec.seed

      lazy = ModelSpec.queries_during { ModelSpec::User.all.each { |user| user.posts.to_a } }
      eager = ModelSpec.queries_during { ModelSpec::User.preload(:posts).all.each { |user| user.posts.to_a } }
      lazy.should eq 4
      eager.should eq 2

      ModelSpec.queries_during do
        ModelSpec::Post.preload(:user).all.map { |post| post.user.try(&.name) }.should eq ["User 0", "User 0", "User 1", "User 1", "User 2", "User 2"]
      end.should eq 2

      ModelSpec.queries_during do
        ModelSpec::User.preload(:profile).all.map { |user| user.profile.try(&.website) }.should eq ["https://u0.example.com", "https://u1.example.com", "https://u2.example.com"]
      end.should eq 2

      ModelSpec.queries_during { ModelSpec::User.preload(:posts, :profile).all.each { |user| user.posts.to_a; user.profile } }.should eq 3
    end
  end

  describe "pagination" do
    it "returns a page with metadata" do
      PostgresSpec.require!
      ModelSpec.seed(users: 5, posts_per_user: 0)
      page = ModelSpec::User.order_by(id: :asc).paginate(page: 2, per_page: 2)
      page.map(&.name).should eq ["User 2", "User 3"]
      page.meta.should eq({page: 2, per_page: 2, total: 5_i64, total_pages: 3, next_page: 3, prev_page: 1})
      page.last_page?.should be_false

      ModelSpec::User.order_by(id: :asc).paginate(page: 3, per_page: 2).map(&.name).should eq ["User 4"]
      ModelSpec::User.order_by(id: :asc).paginate(page: 3, per_page: 2).next_page.should be_nil
    end

    it "chains after scopes and preloads, and clamps user input" do
      PostgresSpec.require!
      ModelSpec.seed
      page = ModelSpec::User.recent.preload(:posts).paginate(page: 1, per_page: 2)
      page.map { |user| {user.name, user.posts.size} }.should eq [{"User 2", 2}, {"User 1", 2}]
      ModelSpec::User.paginate(page: -3, per_page: 0).meta[:per_page].should eq 1
      ModelSpec::User.paginate(page: 1, per_page: 1_000_000).meta[:per_page].should eq 1_000
    end
  end

  describe "N+1 detection" do
    it "raises in :raise mode for lazy reads on batch-loaded records" do
      PostgresSpec.require!
      ModelSpec.seed
      Azu::CONFIG.database.n_plus_one = Azu::DatabaseConfiguration::NPlusOne::Raise

      error = expect_raises(Azu::Model::UnpreloadedAssociation) { ModelSpec::User.all.each { |user| user.posts.to_a } }
      error.message.to_s.should contain "preload(:posts)"

      ModelSpec::User.preload(:posts).all.each { |user| user.posts.to_a }
      ModelSpec::User.first.not_nil!.posts.to_a.size.should eq 2
    end

    it "stays silent when off" do
      PostgresSpec.require!
      ModelSpec.seed
      ModelSpec::User.all.each { |user| user.posts.to_a }
    end
  end
end
