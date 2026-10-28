---
description: Store the users of an API in SQLite with CQL, in the files azu new generates, with one transaction per request.
---

# Working with databases

## What you'll build

By the end of this tutorial, you'll have:

- CQL configured, a `users` table and a `User` model, in the files `azu new` generates
- A migration that creates the table
- `POST /users` and `GET /users` endpoints backed by the database, answering `422` for an invalid user
- One database transaction per request, so a request that fails leaves nothing behind
- Contracts and responses mapped to the model by name

## Prerequisites

- Completed the [Building a user API](building-a-user-api.md) tutorial
- Crystal 1.22.1 or newer, and the Azu CLI (`azu`)
- SQLite (the `sqlite3` library; most systems have it)

Generate an API project that uses SQLite, and install its shards:

```bash
azu new user_api --api --db sqlite --yes
cd user_api
shards install
```

The project's `shard.yml` lists `cql` and the `sqlite3` driver. With `--db postgresql` the initializer below connects
to `postgresql://localhost/user_api_development` instead, and the rest of the tutorial is the same.

## Step 1: Configure CQL, declare the table and write the model

Generate the model:

```bash
azu generate model User name:string email:string:unique 'age:int32?'
```

The generator writes `src/models/user.cr`, adds the `users` table to `src/db/schema.cr` and writes the migration of
Step 2. `azu new` wrote the other two files. Together they look like this, with two validations and a default for
`age` added to the model:

<!-- prelude -->
```crystal
# src/initializers/cql_config.cr
require "sqlite3"
require "azu/cql"

Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/user_api_#{ENV["CRYSTAL_ENV"]? || "development"}.db"
  c.pool.size = ENV["DATABASE_POOL_SIZE"]?.try(&.to_i) || 10
end

Azu::CQL.attach { UserApiDB }

# src/db/schema.cr
UserApiDB = Azu::CQL.schema :user_api_db do
  table :users do
    primary :id, Int64, auto_increment: true
    text :name
    text :email, unique: true
    column :age, Int32, null: true
    timestamps
  end
end

# src/models/user.cr
class User
  include CQL::ActiveRecord::Model(Int64)
  db_context UserApiDB, :users

  property name : String
  property email : String
  property age : Int32?
  property created_at : Time?
  property updated_at : Time?

  validate :name, presence: true, size: 2..50
  validate :email, presence: true, match: /@/

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end
```

- `Azu::CQL.configure` is CQL's own configuration. `DATABASE_URL` wins over the default; `azu new` also writes it to
  `.env.development` and `.env.test`, which the app loads at boot.
- `Azu::CQL.schema` builds the schema from that URL: the `sqlite3://` scheme picks the SQLite adapter, and the first
  query opens the connection. It also attaches the schema to the dev dashboard's Database tab.
  `Azu::CQL.attach { UserApiDB }` does the same for a schema file written in plain CQL; its block runs the first time
  the dashboard needs the schema, after `src/db/schema.cr` has loaded. The generated schema file also declares
  `cql_schema_migrations`, where the migrator records what it has applied.
- The model has one property per column; `id` comes from `CQL::ActiveRecord::Model(Int64)`. The `validate` rules
  run before every save.

The app file `src/user_api.cr` requires `./initializers/**`, then `./db/schema`, then `./models/**`, in that order.

## Step 2: Create the table with a migration

The migration the generator wrote declares the table and creates it; `down` undoes it:

```crystal
# src/db/migrations/20261026120000_create_users.cr
class CreateUsers < CQL::Migration(20261026120000_i64)
  def up
    schema.table :users do
      primary :id, Int64, auto_increment: true
      text :name
      text :email, unique: true
      column :age, Int32, null: true
      timestamps
    end
    schema.users.create!
  end

  def down
    schema.users.drop!
  end
end
```

Create the database and run the migration:

```bash
azu db:create
azu db:migrate
```

`azu db:migrate` applies every migration that is not yet recorded in `cql_schema_migrations`, in version order. The
version is the number in `CQL::Migration(...)`, a timestamp the generator picks. See
[Run migrations](../how-to/database/run-migrations.md) for rollbacks and changes to existing tables.

## Step 3: Save users from an endpoint

Add a request contract, two responses and two endpoints, each in the folder the app file requires:

<!-- prelude -->
```crystal
# src/requests/create_user_request.cr
struct CreateUserRequest
  include Azu::Request

  getter name : String = ""
  getter email : String = ""
  getter age : Int32? = nil
end

# src/responses/user_response.cr
struct UserResponse
  include Azu::Response

  def initialize(@id : Int64?, @name : String, @email : String, @age : Int32?)
  end

  def render
    {id: @id, name: @name, email: @email, age: @age}.to_json
  end
end

# src/responses/users_response.cr
struct UsersResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    @users.map { |user| {id: user.id, name: user.name, email: user.email} }.to_json
  end
end

# src/endpoints/create_user_endpoint.cr
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    user = User.new(create_user_request.name, create_user_request.email, create_user_request.age)
    user.valid_or_422!
    user.save!
    status 201
    content_type "application/json"
    UserResponse.new(user.id, user.name, user.email, user.age)
  end
end

# src/endpoints/list_users_endpoint.cr
struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request, UsersResponse)

  get "/users"

  def call : UsersResponse
    content_type "application/json"
    UsersResponse.new(User.order(:id).all)
  end
end
```

The contract only declares the fields; the rules live on the model, so every `save` checks them.
`valid_or_422!` (from `azu/cql`) runs the model's validations and returns the user, or raises
`Azu::Response::ValidationError`, which the `Rescuer` renders as the same `422` a contract failure gets. `save!`
inserts the row and sets `id`, `created_at` and `updated_at`.

Start the app with `crystal run src/server.cr` and, from another terminal, create a user:

```bash
curl -X POST localhost:4000/users -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"name": "Ada", "email": "ada@example.com", "age": 36}'
```

Response (`201`):

```json
{"id":1,"name":"Ada","email":"ada@example.com","age":36}
```

An invalid user:

```bash
curl -X POST localhost:4000/users -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"name": "A", "email": "nope"}'
```

Response (`422`):

```json
{"type":"about:blank","title":"Validation Error","status":422,"detail":"The request could not be processed due to validation errors.","errors":{"name":["name must have a size of 2..50"],"email":["email must match the pattern /@/"]},"instance":"/users"}
```

`curl localhost:4000/users` lists the saved users: `[{"id":1,"name":"Ada","email":"ada@example.com"}]`.

## Step 4: Run each request in a transaction

An endpoint that writes several rows can fail halfway. This one imports users from a list of e-mail addresses:

```crystal
# src/requests/import_users_request.cr
struct ImportUsersRequest
  include Azu::Request

  getter emails : Array(String) = [] of String
end

# src/endpoints/import_users_endpoint.cr
struct ImportUsersEndpoint
  include Azu::Endpoint(ImportUsersRequest, Azu::Response::Empty)

  post "/users/import"

  def call : Azu::Response::Empty
    import_users_request.emails.each do |email|
      User.new(email.split('@').first, email).valid_or_422!.save!
    end
    status 204
    Azu::Response::Empty.new
  end
end

# src/user_api.cr: the handlers method azu new generated, with the middleware added last
module UserApi
  include Azu

  def self.handlers : Array(HTTP::Handler)
    [
      Azu::Handler::RequestId.new,
      Azu::Handler::Logger.new,
      Azu::Handler::Rescuer.new,
      Azu::Handler::SecurityHeaders.new(hsts: :auto),
      Azu::CQL::Middleware.new(UserApiDB, transaction: true),
    ] of HTTP::Handler
  end
end
```

Keep the `*dev_handlers` line the generated method has after `RequestId`. `src/server.cr` starts the app with these
handlers (`UserApi.start UserApi.handlers`).

`Azu::CQL::Middleware` with `transaction: true` runs the rest of the request in one transaction. It commits when the
status is below 400 and rolls back on an exception or an error status. It sits after `Rescuer`, so the exception that
rolled the transaction back still reaches the `Rescuer` and becomes the response.

Restart the app and import a list whose third address is invalid:

```bash
curl -X POST localhost:4000/users/import -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"emails": ["grace@example.com", "linus@example.com", "nope"]}'
```

Response (`422`):

```json
{"type":"about:blank","title":"Validation Error","status":422,"detail":"The request could not be processed due to validation errors.","errors":{"email":["email must match the pattern /@/"]},"instance":"/users/import"}
```

`curl localhost:4000/users` still lists only Ada: the rows for Grace and Linus were rolled back with the request.
Without the middleware they would stay, saved one statement at a time. The same list without `"nope"` answers `204`
and saves both.

## Step 5: Map contracts to models by name

Step 3 copies fields by hand twice: from the contract into `User.new`, and from the user into `UserResponse.new`.
`azu/cql` generates both copies at compile time, matching fields by name. Add these lines to the three types:

```crystal
# src/requests/create_user_request.cr: the fields a client may set on a User
struct CreateUserRequest
  map_to User, only: [:name, :email, :age]
end

# src/responses/user_response.cr: adds UserResponse.from(user)
struct UserResponse
  include Azu::CQL::FromModel
end

# src/endpoints/create_user_endpoint.cr: the call method, rewritten
struct CreateUserEndpoint
  def call : UserResponse
    user = create_user_request.to_model(User).valid_or_422!
    user.save!
    status 201
    content_type "application/json"
    UserResponse.from(user)
  end
end
```

- `to_model(User)` calls the `User` constructor with the contract's fields of the same names. `map_to ... only:` lists
  the fields that may reach the model, so a field added to the contract later is not copied by accident.
- `UserResponse.from(user)` reads the response's constructor arguments (`id`, `name`, `email`, `age`) from the user.
- A field that is missing or has a type that cannot be converted is a compile error that names both sides.

`POST /users` answers as before: `201` with the user, `422` for an invalid one. The
[CQL bridge](../reference/api/cql-bridge.md) reference lists the conversions and the `rename:` and `except:` options.

## Next steps

{% content-ref url="testing-your-app.md" %}
[testing-your-app.md](testing-your-app.md)
{% endcontent-ref %}

{% content-ref url="deploying-to-production.md" %}
[deploying-to-production.md](deploying-to-production.md)
{% endcontent-ref %}

{% content-ref url="../how-to/database/query-data.md" %}
[query-data.md](../how-to/database/query-data.md)
{% endcontent-ref %}

{% content-ref url="../how-to/database/create-models.md" %}
[create-models.md](../how-to/database/create-models.md)
{% endcontent-ref %}
