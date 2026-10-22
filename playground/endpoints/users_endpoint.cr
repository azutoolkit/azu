require "../../src/azu"
require "../requests/empty_request"
require "../requests/user_form_request"
require "../responses/page"

module ExampleApp
  # People pages share one query and one renderer.
  module PeoplePage
    def self.rows : Array(NamedTuple(id: Int64, name: String, email: String, posts: Int64, initial: String))
      rows = [] of NamedTuple(id: Int64, name: String, email: String, posts: Int64, initial: String)
      DATABASE.query(<<-SQL) do |rs|
        SELECT users.id, users.name, users.email, COUNT(posts.id)
        FROM users LEFT JOIN posts ON posts.user_id = users.id
        GROUP BY users.id ORDER BY users.id DESC
      SQL
        rs.each do
          id, name, email, posts = rs.read(Int64, String, String, Int64)
          rows << {id: id, name: name, email: email, posts: posts, initial: name[0, 1].upcase}
        end
      end
      rows
    end

    def self.render(context : HTTP::Server::Context, form : UserForm, problems : Hash(String, String)) : Page
      Page.new(
        "users.html", context, "users",
        people: rows,
        form_name: form.name, form_email: form.email,
        name_error: problems["name"]?, email_error: problems["email"]?
      )
    end
  end

  struct UsersEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/users"

    def call : Page
      content_type "text/html"
      PeoplePage.render(context, UserForm.new, {} of String => String)
    end
  end

  struct CreateUserEndpoint
    include Azu::Endpoint(UserForm, Page)

    post "/users"

    def call : Page
      form = user_form
      problems = form.problems

      unless problems.empty?
        status 422
        content_type "text/html"
        return PeoplePage.render(context, form, problems)
      end

      DATABASE.exec("INSERT INTO users (name, email) VALUES (?, ?)", form.name, form.email)
      Flash.set(context, notice: "#{form.name} was added.")
      status 303
      header "Location", "/users"
      Page.empty
    end
  end

  struct DeleteUserEndpoint
    include Azu::Endpoint(UserIdRequest, Page)

    delete "/users/:id"

    def call : Page
      id = user_id_request.id
      name = DATABASE.query_one?("SELECT name FROM users WHERE id = ?", id, as: String)

      if name
        DATABASE.exec("DELETE FROM posts WHERE user_id = ?", id)
        DATABASE.exec("DELETE FROM users WHERE id = ?", id)
        Flash.set(context, notice: "#{name} was removed.")
      else
        Flash.set(context, alert: "That person is already gone.")
      end

      status 303
      header "Location", "/users"
      Page.empty
    end
  end
end
