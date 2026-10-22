# Getting Started with Azu

Welcome to Azu! This tutorial will guide you through installing Crystal and Azu, then building your first working application.

## What You'll Learn

By the end of this tutorial, you will have:

- Crystal and Azu installed on your system
- A working Azu application running locally
- Understanding of the basic project structure

## Prerequisites

Before starting, ensure you have:

- A computer running macOS, Linux, or Windows
- Internet connection for downloading dependencies
- A terminal/command line application
- A code editor (VS Code recommended)

## Step 1: Install Crystal

Azu requires **Crystal 1.19.1 or higher**. Install Crystal for your operating system:

### macOS

```bash
# Using Homebrew (recommended)
brew install crystal-lang

# Verify installation
crystal version
# Should output: Crystal 1.x.x
```

### Linux (Ubuntu/Debian)

```bash
# Add Crystal repository
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Install Crystal
sudo apt-get install crystal

# Verify installation
crystal version
```

### Linux (Fedora/CentOS/RHEL)

```bash
# Add Crystal repository
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Fedora
sudo dnf install crystal

# CentOS/RHEL
sudo yum install crystal

# Verify installation
crystal version
```

### Windows

```bash
# Using Chocolatey
choco install crystal

# Using Scoop
scoop install crystal

# Verify installation
crystal version
```

## Step 2: Create Your Project

Create a new Crystal project and add Azu as a dependency:

```bash
# Create project directory
crystal init app my_first_azu_app
cd my_first_azu_app
```

Edit your `shard.yml` to add Azu:

```yaml
name: my_first_azu_app
version: 0.1.0

authors:
  - Your Name <you@example.com>

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.52

crystal: ">= 1.19.1"

license: MIT
```

Install dependencies:

```bash
shards install
```

## Step 3: Create Your First Application

Replace the contents of `src/my_first_azu_app.cr` with:

```crystal
require "azu"

# Define your application module
module MyFirstAzuApp
  include Azu

  configure do |config|
    config.port = 4000
    config.host = "0.0.0.0"
  end
end

# A response turns your data into the body that is sent
struct HelloResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    @message
  end
end

struct GreetResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {message: "Hello, #{@name}!", timestamp: Time.utc.to_rfc3339}.to_json
  end
end

# Create a simple endpoint
struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, HelloResponse)

  get "/"

  def call : HelloResponse
    content_type "text/plain"
    HelloResponse.new("Hello from Azu!")
  end
end

# Create a JSON endpoint
struct GreetEndpoint
  include Azu::Endpoint(Azu::Request, GreetResponse)

  get "/greet/:name"

  def call : GreetResponse
    content_type "application/json"
    GreetResponse.new(params["name"])
  end
end

# Start the server
MyFirstAzuApp.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
] of HTTP::Handler
```

## Step 4: Run Your Application

Start the server:

```bash
crystal run src/my_first_azu_app.cr
```

You should see output like:

```
 AZU   Thu 10/22/2026 09:15:03 ⤑   Info  ⤑  App ⤑  Server started at Thu 10/22/2026 09:15:03.
   ⤑  Environment: Development
   ⤑  Host: 0.0.0.0
   ⤑  Port: 4000
   ⤑  Startup Time: 0.04 millis
```

## Step 5: Test Your Endpoints

Open a new terminal and test your endpoints:

```bash
# Test the hello endpoint
curl http://localhost:4000/
# Output: Hello from Azu!

# Test the greet endpoint
curl http://localhost:4000/greet/World
# Output: {"message":"Hello, World!","timestamp":"2026-10-22T09:15:30Z"}
```

You can also open `http://localhost:4000/` in your browser.

## Understanding the Code

Let's break down what you just created:

### Application Module

```crystal
module MyFirstAzuApp
  include Azu

  configure do |config|
    config.port = 4000
    config.host = "0.0.0.0"
  end
end
```

This defines your application and configures the server settings. `configure` yields the configuration,
and `include Azu` gives the module its `start` method.

### Endpoints

```crystal
struct HelloResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    @message
  end
end

struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, HelloResponse)

  get "/"

  def call : HelloResponse
    content_type "text/plain"
    HelloResponse.new("Hello from Azu!")
  end
end
```

Endpoints handle HTTP requests:
- `include Azu::Endpoint(RequestType, ResponseType)` defines the contract; `Azu::Request` stands for "no request body to validate"
- `get "/"` declares the HTTP method and route
- `def call` contains your handler logic and returns the response object, whose `render` produces the body

### Route Parameters

<!-- skip -->
```crystal
get "/greet/:name"

def call
  params["name"]  # Access route parameters
end
```

The `:name` in the route captures that segment and makes it available via `params`.

## Project Structure

Your project should now look like this:

```
my_first_azu_app/
├── shard.yml           # Dependencies
├── shard.lock          # Locked versions
├── src/
│   └── my_first_azu_app.cr  # Main application
├── lib/                # Installed dependencies
└── spec/               # Test files
```

## Troubleshooting

### "command not found: crystal"

Add Crystal to your PATH:

```bash
export PATH="/usr/local/bin:$PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### "Error resolving dependencies"

Clear the cache and reinstall:

```bash
rm -rf lib/ shard.lock
shards install
```

### Port already in use

Change the port in your configuration or kill the existing process:

```bash
lsof -i :4000
kill -9 <PID>
```

## Next Steps

Congratulations! You've created your first Azu application. Continue learning with:

- [Building a User API](building-a-user-api.md) - Create a complete CRUD API
- [Adding WebSockets](adding-websockets.md) - Add real-time features
- [Working with Databases](working-with-databases.md) - Connect to PostgreSQL or MySQL

---

**Your Azu journey begins!** You now have a working development environment and understand the basics of creating endpoints.
