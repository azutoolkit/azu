module Azu
  enum Method
    Connect
    Delete
    Get
    Head
    Options
    Patch
    Post
    Put
    Trace

    def add_options?
      ![Trace, Connect, Options, Head].includes? self
    end
  end
end
