require "./auth/access"

module Azu
  # The routes the endpoint macros declare (`get "/users"` in an endpoint body), kept until an app
  # takes them. Class-definition time only records; `Azu::App.default` registers them the first time
  # its router is read, so declaring an endpoint no longer touches any router and the same endpoint
  # type can be registered on other apps with `Router::Builder#endpoint`.
  module DeclaredEndpoints
    alias Declaration = Proc(Router, Nil)

    @@mutex = Mutex.new(:reentrant)
    @@declarations = [] of Declaration
    @@declared = Atomic(Int32).new(0)
    @@applied = Atomic(Int32).new(0)

    @@routes = {} of String => Array(Tuple(String, String))
    @@class_options = {} of String => RouteOptions
    @@route_options = {} of Tuple(String, String, String) => RouteOptions

    # The `{verb, path}` pairs declared on the endpoint type called `type_name`.
    def self.routes_of(type_name : String) : Array(Tuple(String, String))
      @@mutex.synchronize { @@routes[type_name] ||= [] of Tuple(String, String) }
    end

    # Returns the class-level `RouteOptions` declared directly on `type_name`.
    def self.class_route_options(type_name : String) : RouteOptions
      @@mutex.synchronize { @@class_options[type_name]? || RouteOptions.new }
    end

    # Sets the class-level `RouteOptions` declared directly on `type_name`.
    def self.set_class_route_options(type_name : String, options : RouteOptions) : RouteOptions
      @@mutex.synchronize { @@class_options[type_name] = options }
    end

    # Records inline `RouteOptions` declared on a specific `(verb, path)` macro inside `type_name`.
    def self.set_route_options(type_name : String, verb : String, path : String, options : RouteOptions) : Nil
      @@mutex.synchronize { @@route_options[{type_name, verb, path}] = options }
    end

    # Returns inline `RouteOptions` declared on `(verb, path)` inside `type_name`, if any.
    def self.route_options_of(type_name : String, verb : String, path : String) : RouteOptions?
      @@mutex.synchronize { @@route_options[{type_name, verb, path}]? }
    end

    # Records *declaration*, the *route* it adds, for the global router (*into*, read as it is: reading
    # `CONFIG.router` would apply the declarations). Once that router is frozen (its app serves) the declaration
    # raises `Router::Frozen` here: left pending, it would make every later request of `App.default` raise.
    def self.declare(declaration : Declaration, route : String = "a route", into : Router = CONFIG.@router) : Nil
      raise Router::Frozen.for(route) if into.frozen?
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
