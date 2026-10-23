module Azu
  # The routes the endpoint macros declare (`get "/users"` in an endpoint body), kept until an app
  # takes them. Class-definition time only records; `Azu::App.default` registers them the first time
  # its router is read, so declaring an endpoint no longer touches any router and the same endpoint
  # type can be registered on other apps with `Router::Builder#endpoint`.
  module DeclaredEndpoints
    alias Declaration = Proc(Router, Nil)

    @@mutex = Mutex.new
    @@declarations = [] of Declaration
    @@declared = Atomic(Int32).new(0)
    @@applied = Atomic(Int32).new(0)

    @@routes = {} of String => Array(Tuple(String, String))

    # The `{verb, path}` pairs declared on the endpoint type called `type_name`.
    def self.routes_of(type_name : String) : Array(Tuple(String, String))
      @@mutex.synchronize { @@routes[type_name] ||= [] of Tuple(String, String) }
    end

    def self.declare(declaration : Declaration) : Nil
      @@mutex.synchronize do
        @@declarations << declaration
        @@declared.set(@@declarations.size)
      end
    end

    # Registers every declaration not yet applied on `router`, in declaration order. One that raises
    # (a duplicate route) stays pending and raises again on the next call, so the failure is not lost.
    def self.apply_to(router : Router) : Nil
      return if @@applied.get == @@declared.get
      @@mutex.synchronize do
        while (index = @@applied.get) < @@declarations.size
          @@declarations[index].call(router)
          @@applied.set(index + 1)
        end
      end
    end
  end
end
