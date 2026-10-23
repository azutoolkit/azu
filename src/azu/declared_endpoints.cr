module Azu
  # The routes the endpoint macros declare (`get "/users"` in an endpoint body), kept until an app
  # takes them. Class-definition time only records; `Azu::App.default` registers them the first time
  # its router is read, so declaring an endpoint no longer touches any router and the same endpoint
  # type can be registered on other apps with `Router::Builder#endpoint`.
  module DeclaredEndpoints
    alias Declaration = Proc(Router, Nil)

    @@mutex = Mutex.new
    @@declarations = [] of Declaration
    @@applied = 0

    def self.declare(declaration : Declaration) : Nil
      @@mutex.synchronize { @@declarations << declaration }
    end

    # Registers every declaration not yet applied on `router`, in declaration order.
    def self.apply_to(router : Router) : Nil
      return if @@applied == @@declarations.size
      @@mutex.synchronize do
        while @@applied < @@declarations.size
          declaration = @@declarations[@@applied]
          @@applied += 1
          declaration.call(router)
        end
      end
    end
  end
end
