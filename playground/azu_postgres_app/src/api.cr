module BlogApp
  struct EmptyRequest
    include Azu::Request
  end

  struct JsonResponse
    include Azu::Response

    def initialize(@json : String)
    end

    def render
      @json
    end
  end

  # Shared by the endpoints below.
  module Helpers
    def json(payload) : JsonResponse
      content_type "application/json"
      JsonResponse.new(payload.to_json)
    end

    def not_found(what : String) : JsonResponse
      status 404
      json({error: "#{what} not found"})
    end

    def invalid(error : CQL::ActiveRecord::Validations::ValidationError) : JsonResponse
      status 422
      json({error: error.message})
    end

    def page_params : {Int32, Int32}
      {params["page"]?.try(&.to_i?) || 1, params["per_page"]?.try(&.to_i?) || 5}
    end

    def user_json(user : User) : NamedTuple
      {id: user.id, name: user.name, email: user.email, role: user.role, token: user.token.to_s, settings: user.settings, posts: user.posts.size}
    end

    def post_json(post : Post) : NamedTuple
      {id: post.id, title: post.title, status: post.status, views: post.views, author: post.user.try(&.name), comments: post.comments.size}
    end
  end

  struct IndexEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/"

    def call : JsonResponse
      json({
        dashboard: "/__dev",
        try:       [
          "GET /users?page=1&per_page=3", "GET /users/1", "POST /users name=Ada email=ada@example.com", "PUT /users/1 name=Ada+Lovelace",
          "DELETE /users/2", "GET /posts", "GET /posts/n_plus_one", "POST /users/1/posts title=Hello", "POST /posts/1/publish",
          "DELETE /posts/1", "POST /posts/1/restore", "POST /signup email=new@example.com fail=true", "GET /health",
        ],
      })
    end
  end

  # Pagination with preloading: two queries for any page size (plus the count).
  struct ListUsersEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/users"

    def call : JsonResponse
      page, per_page = page_params
      users = User.recent.preload(:posts).paginate(page: page, per_page: per_page)
      json({data: users.map { |user| user_json(user) }, meta: users.meta})
    end
  end

  struct ShowUserEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/users/:id"

    def call : JsonResponse
      user = User.find?(params.path["id"].to_i64)
      user ? json(user_json(user)) : not_found("user")
    end
  end

  struct CreateUserEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    post "/users"

    def call : JsonResponse
      user = User.create!(name: params["name"]? || "", email: params["email"]? || "")
      status 201
      json(user_json(user))
    rescue ex : CQL::ActiveRecord::Validations::ValidationError
      invalid(ex)
    end
  end

  struct UpdateUserEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    put "/users/:id"

    def call : JsonResponse
      user = User.find?(params.path["id"].to_i64) || return not_found("user")
      user.name = params["name"] if params["name"]?
      user.save!
      json(user_json(user))
    rescue ex : CQL::ActiveRecord::Validations::ValidationError
      invalid(ex)
    end
  end

  # The database cascades the delete to the user's posts and comments.
  struct DeleteUserEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    delete "/users/:id"

    def call : JsonResponse
      user = User.find?(params.path["id"].to_i64) || return not_found("user")
      user.delete!
      json({deleted: true})
    end
  end

  # Published posts with their authors preloaded.
  struct ListPostsEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/posts"

    def call : JsonResponse
      page, per_page = page_params
      posts = Post.published.order_by(id: :desc).preload(:user, :comments).paginate(page: page, per_page: per_page)
      json({data: posts.map { |post| post_json(post) }, meta: posts.meta})
    end
  end

  # Deliberate N+1: each post lazily loads its author and comments. With `n_plus_one = Warn`
  # the log names the missing `preload`, and the dashboard's Database tab flags the pattern.
  struct NPlusOneEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/posts/n_plus_one"

    def call : JsonResponse
      json(Post.recent.all.map { |post| post_json(post) })
    end
  end

  struct CreatePostEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    post "/users/:id/posts"

    def call : JsonResponse
      user = User.find?(params.path["id"].to_i64) || return not_found("user")
      post = Post.create!(user_id: user.id.not_nil!, title: params["title"]? || "", body: params["body"]? || "")
      status 201
      json(post_json(post))
    rescue ex : CQL::ActiveRecord::Validations::ValidationError
      invalid(ex)
    end
  end

  struct PublishPostEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    post "/posts/:id/publish"

    def call : JsonResponse
      post = Post.find?(params.path["id"].to_i64) || return not_found("post")
      post.status = "published"
      post.save!
      json(post_json(post))
    end
  end

  # Soft delete: the row stays with deleted_at set and disappears from every query.
  struct DeletePostEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    delete "/posts/:id"

    def call : JsonResponse
      post = Post.find?(params.path["id"].to_i64) || return not_found("post")
      post.delete!
      json({deleted: true, soft: true, visible_posts: Post.count, all_posts: Post.count_with_deleted})
    end
  end

  struct RestorePostEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    post "/posts/:id/restore"

    def call : JsonResponse
      restored = Post.restore!(params.path["id"].to_i64)
      json({restored: restored})
    end
  end

  # All-or-nothing sign-up: user, first post and welcome comment commit together.
  # `fail=true` raises inside the block and PostgreSQL rolls everything back.
  struct SignupEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    post "/signup"

    def call : JsonResponse
      email = params["email"]? || "new#{Random.rand(100_000)}@example.com"
      fail = params["fail"]? == "true"
      created = nil
      User.transaction do |tx|
        user = User.create!(tx, email: email, name: "New Member")
        post = Post.create!(tx, user_id: user.id.not_nil!, title: "Hello, world", status: "published")
        Comment.create!(tx, post_id: post.id.not_nil!, user_id: user.id.not_nil!, body: "First!")
        raise DB::Rollback.new if fail
        created = user
      end
      created ? json({committed: true, user: user_json(created)}) : json({committed: false, users: User.count})
    rescue ex : CQL::ActiveRecord::Validations::ValidationError
      invalid(ex)
    end
  end

  struct HealthEndpoint
    include Azu::Endpoint(EmptyRequest, JsonResponse)
    include Helpers
    get "/health"

    def call : JsonResponse
      healthy = Azu::Database.healthy?
      status 503 unless healthy
      json({database: healthy, pool: Azu::Database.pool})
    end
  end
end
