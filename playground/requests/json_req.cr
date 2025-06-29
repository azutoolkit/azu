require "json"
require "../../src/azu"

module ExampleApp
  struct JsonReq
    include Azu::Request

    @id : Int64?
    @users : Array(String)

    getter id, users, config

    def initialize(@id : Int64? = nil, @users : Array(String) = [] of String)
    end

    struct Config
      include Azu::Request

      @allowed : Bool?
      getter allowed

      def initialize(@allowed : Bool? = false)
      end
    end
  end
end
