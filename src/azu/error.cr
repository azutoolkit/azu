module Azu
  class Error(Code) < Exception
    getter code : Int32 = Code
  end
end
