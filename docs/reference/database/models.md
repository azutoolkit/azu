# Models (`Azu::Model`)

`require "azu/database"` (or `require "azu/model"`). A model is a thin DSL over CQL's active record:
the declarations below populate CQL's schema, so there is no schema constant or connection code.

```crystal
class Post < Azu::Model
  table :posts

  column id : Int64, primary_key: true
  column user_id : Int64
  column title : String
  column status : String = "draft"
  column views : Int32 = 0
  timestamps
  soft_delete

  validates :title, presence: true, length: 3..200

  belongs_to user : User
  has_many comments : Comment, foreign_key: :post_id, dependent: :delete_all

  scope :published, -> { where(status: "published") }
end
```

Order matters: `table`, then the `primary_key` column, then other columns, then associations,
validations and scopes.

## Columns

`column name : Type [= default], **options`

| Option | Meaning |
| --- | --- |
| `primary_key: true` | Selects the key type and includes CQL's model for it |
| `unique: true` | Adds a uniqueness validation (back it with a unique index) |
| `index: true` | Registers the index in the CQL schema |
| `validate: :email \| :url \| :uuid` | Format validation |

Supported types: `String`, `Int32`, `Int64`, `Float32`, `Float64`, `Bool`, `Time`, `UUID`, `JSON::Any`
(json/jsonb, written as JSON text) and nilable versions (`String?` is a nullable column). A column
without a default gets a neutral one so `Model.new` always works. UUID primary keys and array
columns are not supported by models yet.

PostgreSQL enum columns are read and written as `String`.

`timestamps` adds `created_at` / `updated_at`, maintained on save.
`soft_delete` adds a nullable `deleted_at`: `delete!` marks the row, queries hide it, and
`restore!`, `force_delete!`, `count_with_deleted` and `count_only_deleted` are available.

## Validations

```crystal
validates :email, presence: true, format: :email, uniqueness: true, length: 3..120
validates :name, presence: true, length: 2..80
```

* `format:` takes `:email`, `:url`, `:uuid` or a Regex; `uniqueness: true` (or `{message: "..."}`) checks the
  table with the record itself excluded.
* CQL keeps one rule set per attribute: use one `validates` per field.
* `valid?`, `errors` (each with `message`), `save!` and `create!` raise
  `CQL::ActiveRecord::Validations::ValidationError` with all messages.

## Associations

| Macro | Notes |
| --- | --- |
| `has_many posts : Post, foreign_key: :user_id` | Loaded lazily; `preload(:posts)` loads all parents' children in one query |
| `has_one profile : Profile, foreign_key: :user_id` | `preload(:profile)` works too |
| `belongs_to user : User` | Foreign key defaults to `user_id`; declare that column first |
| `many_to_many tags : Tag, through: Tagging, foreign_key: :post_id, association_foreign_key: :tag_id` | Enumerable collection with `<<` (idempotent), `delete(tag)`, `clear` operating on the join rows |

`has_many ... dependent:` is applied by `delete!`: `:destroy` calls `delete!` on each child,
`:delete_all` removes them in one statement, `:restrict_with_error` raises
`Azu::Model::DependentRecordsExist` while children exist. (For soft-deleting children prefer database
level `ON DELETE CASCADE`.)

Inside a namespace write association targets as full paths (`Blog::Post`): CQL resolves them at
compile time.

## Querying

```crystal
User.find!(1)                       # raises if missing; find? returns nil
User.where(role: "admin").all
User.admins.recent.to_a             # scopes chain
User.order_by(id: :desc).paginate(page: 2, per_page: 20)
User.preload(:posts, :profile).all  # one extra query per association
User.count
```

`paginate` returns `Azu::Page(T)`: enumerable, with `meta` (`page`, `per_page`, `total`, `total_pages`,
`next_page`, `prev_page`), `first_page?`, `last_page?`. `page` is clamped to at least 1 and `per_page`
to 1..1000.

## Writing and transactions

```crystal
user = User.create!(email: "ada@example.com", name: "Ada")
user.name = "Ada Lovelace"
user.save!
user.delete!

User.transaction do |tx|
  author = User.create!(tx, email: "bob@example.com", name: "Bob")
  Post.create!(tx, user_id: author.id.not_nil!, title: "Hello")
  raise DB::Rollback.new if something_wrong # rolls back without raising
end
```

An unhandled exception inside the block also rolls back. Transactions appear in the dashboard with
their statements and outcome.

## N+1 detection

Records loaded in a batch remember it. Reading an association that was not preloaded from such a
record is reported according to `c.database.n_plus_one`:

| Mode | Behaviour |
| --- | --- |
| `Off` | Nothing |
| `Warn` | Logs `N+1 query: Post#user was loaded lazily for a record from a batch of 13; add preload(:user)` |
| `Raise` | Raises `Azu::Model::UnpreloadedAssociation` with the same text |

The dashboard's Database tab additionally flags repeated statements per request.
