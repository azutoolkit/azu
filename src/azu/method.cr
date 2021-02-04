module Azu
  # :nodoc:
  enum Method
    # The CONNECT method establishes a tunnel to the server identified by the target resource.
    Connect
    # The DELETE method deletes the specified resource.
    Delete
    # The GET method requests a representation of the specified resource. Requests using GET should only retrieve data.
    Get
    # The HEAD method asks for a response identical to that of a GET request, but without the response body.
    Head
    # The OPTIONS method is used to describe the communication options for the target resource.
    Options
    # The PATCH method is used to apply partial modifications to a resource.
    Patch
    # The POST method is used to submit an entity to the specified resource, often causing a change in state or side effects on the server.
    Post
    # The PUT method replaces all current representations of the target resource with the request payload.
    Put
    # The TRACE method performs a message loop-back test along the path to the target resource.
    Trace

    def add_options?
      ![Trace, Connect, Options, Head].includes? self
    end
  end
end
