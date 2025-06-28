require "../../src/azu"

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

# Create mock contexts
puts "\n1. Testing UserEndpoint:"
user_request = HTTP::Request.new("GET", "/users")
user_context = HTTP::Server::Context.new(user_request, HTTP::Server::Response.new(IO::Memory.new))

# Simulate router processing
result = router.radix.find("/get/users")
if result.found?
  route = result.payload
  endpoint_class_name = route.endpoint.class.name
  user_context.request.headers["X-Azu-Endpoint"] = endpoint_class_name

  # Simulate what the logger would do
  full_name = user_context.request.headers["X-Azu-Endpoint"]?
  simplified_name = full_name.try(&.split("::").last) || "unknown"

  puts "   Full class name: #{full_name}"
  puts "   Simplified name: #{simplified_name}"
  puts "   Log would show: GET /users Endpoint:#{simplified_name}"
end

puts "\n2. Testing API::V1::ProductEndpoint:"
product_request = HTTP::Request.new("GET", "/products")
product_context = HTTP::Server::Context.new(product_request, HTTP::Server::Response.new(IO::Memory.new))

# Simulate router processing
result = router.radix.find("/get/products")
if result.found?
  route = result.payload
  endpoint_class_name = route.endpoint.class.name
  product_context.request.headers["X-Azu-Endpoint"] = endpoint_class_name

  # Simulate what the logger would do
  full_name = product_context.request.headers["X-Azu-Endpoint"]?
  simplified_name = full_name.try(&.split("::").last) || "unknown"

  puts "   Full class name: #{full_name}"
  puts "   Simplified name: #{simplified_name}"
  puts "   Log would show: GET /products Endpoint:#{simplified_name}"
end

puts "\n3. Simulating actual log output format:"
puts "   127.0.0.1 ⤑ GET Path:/users Endpoint:UserEndpoint Status:200 Latency:1.23ms"
puts "   127.0.0.1 ⤑ GET Path:/products Endpoint:ProductEndpoint Status:200 Latency:2.45ms"

puts "\n4. Async logging context format:"
async_logger = Azu::AsyncLogging::AsyncLogger.new("demo")
puts "   Context would include:"
puts "   {\"method\" => \"GET\", \"path\" => \"/users\", \"endpoint\" => \"UserEndpoint\", \"status\" => \"200\"}"

puts "\n✅ Endpoint Class Name Logging Demo Completed!"
puts "\nKey Features:"
puts "• Full endpoint class path captured: #{API::V1::ProductEndpoint.new.class.name}"
puts "• Simplified display name: #{API::V1::ProductEndpoint.new.class.name.split("::").last}"
puts "• Available in both sync and async logging"
puts "• Stored in HTTP context headers for middleware access"
puts "• Integrated with existing log formatters"
