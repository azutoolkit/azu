require "../../spec_helper"
require "../../support/postgres"
require "../../../src/azu/model"

# PostgreSQL-specific column kinds and association shapes, each in its own table.
module ModelFeaturesSpec
  class Account < Azu::Model
    table :mf_spec_accounts
    column id : Int64, primary_key: true
    column name : String
    column token : UUID
    column settings : JSON::Any
    timestamps
  end

  class Article < Azu::Model
    table :mf_spec_articles
    column id : Int64, primary_key: true
    column title : String
    soft_delete
  end

  class Tag < Azu::Model
    table :mf_spec_tags
    column id : Int64, primary_key: true
    column label : String
  end

  class Tagging < Azu::Model
    table :mf_spec_taggings
    column id : Int64, primary_key: true
    column tag_id : Int64
    column note_id : Int64
  end

  class Note < Azu::Model
    table :mf_spec_notes
    column id : Int64, primary_key: true
    column body : String

    many_to_many tags : ModelFeaturesSpec::Tag, through: ModelFeaturesSpec::Tagging, foreign_key: :note_id, association_foreign_key: :tag_id
  end

  class Author < Azu::Model
    table :mf_spec_authors
    column id : Int64, primary_key: true
    column name : String

    has_many books : ModelFeaturesSpec::Book, foreign_key: :author_id, dependent: :destroy
  end

  class Book < Azu::Model
    table :mf_spec_books
    column id : Int64, primary_key: true
    column author_id : Int64
    column title : String
    column state : String = "draft"
  end

  class Publisher < Azu::Model
    table :mf_spec_publishers
    column id : Int64, primary_key: true
    column name : String

    has_many imprints : ModelFeaturesSpec::Imprint, foreign_key: :publisher_id, dependent: :restrict_with_error
  end

  class Imprint < Azu::Model
    table :mf_spec_imprints
    column id : Int64, primary_key: true
    column publisher_id : Int64
    column title : String
  end

  class Studio < Azu::Model
    table :mf_spec_studios
    column id : Int64, primary_key: true
    column name : String

    has_many series : ModelFeaturesSpec::Series, foreign_key: :studio_id, dependent: :delete_all
  end

  class Series < Azu::Model
    table :mf_spec_series
    column id : Int64, primary_key: true
    column studio_id : Int64
    column title : String
  end

  TABLES = %w(mf_spec_notes mf_spec_series mf_spec_studios mf_spec_imprints mf_spec_publishers mf_spec_books mf_spec_authors mf_spec_taggings mf_spec_tags mf_spec_articles mf_spec_accounts)

  def self.reset_tables
    schema = Azu::Database.schema
    TABLES.each { |table| schema.exec("DROP TABLE IF EXISTS #{table} CASCADE") }
    schema.exec("DROP TYPE IF EXISTS mf_spec_state")
    schema.exec("CREATE TABLE mf_spec_notes (id BIGSERIAL PRIMARY KEY, body TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_tags (id BIGSERIAL PRIMARY KEY, label TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_taggings (id BIGSERIAL PRIMARY KEY, note_id BIGINT NOT NULL REFERENCES mf_spec_notes(id), tag_id BIGINT NOT NULL REFERENCES mf_spec_tags(id))")
    schema.exec("CREATE TABLE mf_spec_publishers(id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_imprints (id BIGSERIAL PRIMARY KEY, publisher_id BIGINT NOT NULL REFERENCES mf_spec_publishers(id), title TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_studios (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_series (id BIGSERIAL PRIMARY KEY, studio_id BIGINT NOT NULL REFERENCES mf_spec_studios(id), title TEXT NOT NULL)")
    schema.exec("CREATE TYPE mf_spec_state AS ENUM ('draft', 'published')")
    schema.exec("CREATE TABLE mf_spec_accounts (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL, token UUID NOT NULL, settings JSONB NOT NULL DEFAULT '{}', created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ)")
    schema.exec("CREATE TABLE mf_spec_articles (id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL, deleted_at TIMESTAMPTZ)")
    schema.exec("CREATE TABLE mf_spec_authors (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)")
    schema.exec("CREATE TABLE mf_spec_books (id BIGSERIAL PRIMARY KEY, author_id BIGINT NOT NULL REFERENCES mf_spec_authors(id), title TEXT NOT NULL, state mf_spec_state NOT NULL DEFAULT 'draft')")
  end
end

describe "Azu::Model on PostgreSQL types" do
  before_all do
    if PostgresSpec.available?
      Azu::CONFIG.database.url = PostgresSpec.url
      Azu::Database.schema = nil
      Azu::Database.schema
    end
  end

  before_each { ModelFeaturesSpec.reset_tables if PostgresSpec.available? }
  after_all do
    if PostgresSpec.available?
      ModelFeaturesSpec::TABLES.each { |table| Azu::Database.schema.exec("DROP TABLE IF EXISTS #{table} CASCADE") }
      Azu::Database.schema.exec("DROP TYPE IF EXISTS mf_spec_state")
    end
  end

  it "stores UUID columns natively" do
    PostgresSpec.require!
    token = UUID.random
    account = ModelFeaturesSpec::Account.create!(name: "Acme", token: token)
    ModelFeaturesSpec::Account.find!(account.id).token.should eq token
    ModelFeaturesSpec::Account.where(name: "Acme").first.not_nil!.token.should eq token
  end

  it "round-trips JSONB through JSON::Any, on create and update" do
    PostgresSpec.require!
    settings = JSON.parse(%({"theme": "dark", "limits": {"seats": 5}}))
    account = ModelFeaturesSpec::Account.create!(name: "Acme", token: UUID.random, settings: settings)
    found = ModelFeaturesSpec::Account.find!(account.id)
    found.settings["limits"]["seats"].as_i.should eq 5

    found.settings = JSON.parse(%({"theme": "light"}))
    found.save!
    ModelFeaturesSpec::Account.find!(account.id).settings["theme"].as_s.should eq "light"
  end

  it "soft deletes, hides, restores and force deletes" do
    PostgresSpec.require!
    article = ModelFeaturesSpec::Article.create!(title: "Hello")
    article.delete!
    article.deleted?.should be_true
    ModelFeaturesSpec::Article.count.should eq 0
    ModelFeaturesSpec::Article.count_with_deleted.should eq 1
    article.restore!
    ModelFeaturesSpec::Article.count.should eq 1
    article.force_delete!
    ModelFeaturesSpec::Article.count_with_deleted.should eq 0
  end

  it "reads an enum column back as a string" do
    PostgresSpec.require!
    author = ModelFeaturesSpec::Author.create!(name: "Ada")
    ModelFeaturesSpec::Book.create!(author_id: author.id.not_nil!, title: "Notes", state: "published")
    ModelFeaturesSpec::Book.all.first.state.should eq "published"
  end

  it "destroys dependent records with dependent: :destroy" do
    PostgresSpec.require!
    author = ModelFeaturesSpec::Author.create!(name: "Ada")
    2.times { |i| ModelFeaturesSpec::Book.create!(author_id: author.id.not_nil!, title: "Book #{i}") }
    author.books.size.should eq 2
    author.delete!
    ModelFeaturesSpec::Book.count.should eq 0
    ModelFeaturesSpec::Author.count.should eq 0
  end

  it "loads and manages many_to_many through a join table" do
    PostgresSpec.require!
    note = ModelFeaturesSpec::Note.create!(body: "Remember")
    crystal = ModelFeaturesSpec::Tag.create!(label: "crystal")
    pg = ModelFeaturesSpec::Tag.create!(label: "postgres")
    note.tags << crystal
    note.tags << pg
    ModelFeaturesSpec::Note.find!(note.id).tags.map(&.label).sort!.should eq ["crystal", "postgres"]
    note.tags.delete(crystal)
    ModelFeaturesSpec::Note.find!(note.id).tags.map(&.label).should eq ["postgres"]
  end

  it "restricts deleting a parent that still has children" do
    PostgresSpec.require!
    publisher = ModelFeaturesSpec::Publisher.create!(name: "Acme Press")
    ModelFeaturesSpec::Imprint.create!(publisher_id: publisher.id.not_nil!, title: "Classics")
    expect_raises(Azu::Model::DependentRecordsExist, /still has imprints/) { publisher.delete! }
    ModelFeaturesSpec::Publisher.count.should eq 1
  end

  it "removes children in one statement with dependent: :delete_all" do
    PostgresSpec.require!
    studio = ModelFeaturesSpec::Studio.create!(name: "Acme Studio")
    2.times { |i| ModelFeaturesSpec::Series.create!(studio_id: studio.id.not_nil!, title: "Series #{i}") }
    studio.delete!
    ModelFeaturesSpec::Series.count.should eq 0
    ModelFeaturesSpec::Studio.count.should eq 0
  end
end
