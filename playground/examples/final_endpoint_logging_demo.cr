require "../../src/azu"

# Opt in to Azu's log format; requiring azu no longer configures Log
Azu.setup_logging

# Demo response
struct DemoResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    @message
  end
end

# Demo endpoints with different class names
struct UserEndpoint
  include Azu::Endpoint(Azu::Request, DemoResponse)

  def call : DemoResponse
    DemoResponse.new("User endpoint response")
  end
end

module API
  module V1
    struct ProductEndpoint
      include Azu::Endpoint(Azu::Request, DemoResponse)

      def call : DemoResponse
        DemoResponse.new("Product endpoint response")
      end
    end
  end
end

# Routes a GET the way the server does: the router stores the endpoint's class name in the X-Azu-Endpoint header
def show(router : Azu::Router, path : String) : Nil
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(IO::Memory.new))
  router.process(context)

  # Simulate what the logger would do
  full_name = context.request.headers["X-Azu-Endpoint"]?
  simplified_name = full_name.try(&.split("::").last) || "unknown"

  puts "   Full class name: #{full_name}"
  puts "   Simplified name: #{simplified_name}"
  puts "   Log would show: GET #{path} Endpoint:#{simplified_name}"
end

# Demo the endpoint logging functionality
puts "🎯 Endpoint Class Name Logging Demo"
puts "=" * 50

# Create router and endpoints
router = Azu::Router.new
user_endpoint = UserEndpoint.new
product_endpoint = API::V1::ProductEndpoint.new

# Add routes
router.get("/users", user_endpoint)
router.get("/products", product_endpoint)

puts "\n1. Testing UserEndpoint:"
show(router, "/users")

puts "\n2. Testing API::V1::ProductEndpoint:"
show(router, "/products")

puts "\n3. Simulating actual log output format:"
puts "   127.0.0.1 ⤑ GET Path:/users Endpoint:UserEndpoint Status:200 Latency:1.23ms"
puts "   127.0.0.1 ⤑ GET Path:/products Endpoint:ProductEndpoint Status:200 Latency:2.45ms"

puts "\n4. Async logging context format:"
_ = Azu::AsyncLogging::AsyncLogger.new("demo")
puts "   Context would include:"
puts "   {\"method\" => \"GET\", \"path\" => \"/users\", \"endpoint\" => \"UserEndpoint\", \"status\" => \"200\"}"

puts "\n✅ Endpoint Class Name Logging Demo Completed!"
puts "\nKey Features:"
puts "• Full endpoint class path captured: #{API::V1::ProductEndpoint.new.class.name}"
puts "• Simplified display name: #{API::V1::ProductEndpoint.new.class.name.split("::").last}"
puts "• Available in both sync and async logging"
puts "• Stored in HTTP context headers for middleware access"
puts "• Integrated with existing log formatters"
