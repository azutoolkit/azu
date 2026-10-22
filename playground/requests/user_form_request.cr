require "../../src/azu"

module ExampleApp
  # The "add a person" form. Defaults keep a blank submission a validation problem
  # (shown inline) instead of an unparseable request.
  struct UserForm
    include Azu::Request

    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    @name : String = ""
    @email : String = ""

    def initialize(@name : String = "", @email : String = "")
    end

    def name : String
      @name.strip
    end

    def email : String
      @email.strip
    end

    validate name, size: 2..60, message: "Enter a name between 2 and 60 characters."
    validate email, match: EMAIL, message: "Enter a valid email address, like ada@example.com."

    # Problems keyed by field, for inline messages.
    def problems : Hash(String, String)
      errors.to_h { |error| {error.field.to_s, error.message} }
    end
  end

  # Identifies one person in the URL (`/users/:id`).
  struct UserIdRequest
    include Azu::Request

    getter id : Int64

    def initialize(@id : Int64)
    end
  end

  # Which counter button was pressed on the cache page.
  struct CounterForm
    include Azu::Request

    ACTIONS = %w(increment decrement reset)

    @action : String = "increment"

    def initialize(@action : String = "increment")
    end

    def action : String
      ACTIONS.includes?(@action) ? @action : "increment"
    end
  end
end
