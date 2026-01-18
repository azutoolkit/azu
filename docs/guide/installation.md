# Installation Guide

Get Azu up and running on your system with this comprehensive installation guide. This guide covers everything from prerequisites to troubleshooting common issues.

## Prerequisites

Before installing Azu, ensure you have the following prerequisites installed on your system.

### Crystal Language

Azu requires **Crystal 0.35.0 or higher**. Install Crystal first:

#### macOS

```bash
# Using Homebrew (recommended)
brew install crystal-lang

# Verify installation
crystal version
# Should output: Crystal 1.x.x
```

#### Linux (Ubuntu/Debian)

```bash
# Add Crystal repository
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Install Crystal
sudo apt-get install crystal

# Verify installation
crystal version
```

#### Linux (CentOS/RHEL/Fedora)

```bash
# Add Crystal repository
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Install Crystal (Fedora)
sudo dnf install crystal

# Install Crystal (CentOS/RHEL)
sudo yum install crystal

# Verify installation
crystal version
```

#### Windows

```bash
# Using Chocolatey
choco install crystal

# Using Scoop
scoop install crystal

# Verify installation
crystal version
```

### System Requirements

- **Memory**: Minimum 512MB RAM (2GB+ recommended)
- **Storage**: 100MB free space for Crystal + dependencies
- **Network**: Internet connection for downloading shards

### Development Tools (Optional)

For the best development experience, install these tools:

```bash
# Git for version control
git --version

# A code editor (VS Code recommended)
code --version

# HTTP client for testing (curl, httpie, or Postman)
curl --version
```

## Installing Azu

### Method 1: New Project (Recommended)

Create a new Crystal project and add Azu as a dependency:

```bash
# Create a new Crystal application
crystal init app my-azu-app
cd my-azu-app
```

Edit your `shard.yml`:

```yaml
name: my-azu-app
version: 0.1.0

authors:
  - Your Name <you@example.com>

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.26

crystal: >= 0.35.0

license: MIT
```

Install dependencies:

```bash
# Install Azu and its dependencies
shards install

# Verify installation
crystal run --help
```

### Method 2: Add to Existing Project

If you have an existing Crystal project:

```bash
# Navigate to your project directory
cd your-existing-project
```

Add to your `shard.yml`:

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.26
```

Install:

```bash
shards install
```

### Method 3: Global Installation (Development)

For development and testing:

```bash
# Clone the repository
git clone https://github.com/azutoolkit/azu.git
cd azu

# Install dependencies
shards install

# Build the example application
crystal build --release playground/example_app.cr

# Run the example
./example_app
```

## Verification

Verify your installation with a simple test:

### 1. Create a Test File

Create `test_azu.cr`:

```crystal
require "azu"

# Simple test application
module TestApp
  include Azu

  configure do |config|
    config.port = 4001  # Use different port to avoid conflicts
  end

  # Define a simple endpoint
  struct HelloEndpoint
    include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

    get "/"

    def call : Azu::Response::Text
      Azu::Response::Text.new("Hello, Azu is working!")
    end
  end

  # Register the endpoint
  router do
    root :web, HelloEndpoint
  end
end

# Start the application
TestApp.start
```

### 2. Run the Test

```bash
# Run the test application
crystal run test_azu.cr
```

You should see output like:

```
Server started at Mon 12/04/2023 10:30:45.
   ⤑  Environment: development
   ⤑  Host: 0.0.0.0
   ⤑  Port: 4001
   ⤑  Startup Time: 12.34 millis
```

### 3. Test the Endpoint

```bash
# Test the endpoint
curl http://localhost:4001/

# Expected output:
# Hello, Azu is working!
```

## Troubleshooting Installation

### Common Issues

#### Issue: "command not found: crystal"

**Solution:**

```bash
# Add Crystal to your PATH
export PATH="/usr/local/bin:$PATH"

# Or add to your shell profile (~/.bashrc, ~/.zshrc, etc.)
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

#### Issue: "shards: command not found"

**Solution:**

```bash
# Install shards separately if needed
crystal install shards

# Or install via package manager
# macOS: brew install crystal-lang
# Linux: Follow Crystal installation guide
```

#### Issue: "Error resolving dependencies"

**Solution:**

```bash
# Clear shard cache
rm -rf lib/
rm shard.lock

# Reinstall dependencies
shards install
```

#### Issue: "Permission denied" errors

**Solution:**

```bash
# Fix permissions
sudo chown -R $(whoami) /usr/local/bin
sudo chmod +x /usr/local/bin/crystal

# Or install with user permissions
crystal install --user
```

### Version Compatibility

Check version compatibility:

```bash
# Check Crystal version
crystal version

# Check Azu version in shard.lock
cat shard.lock | grep azu

# Expected output shows compatible versions
```

### Network Issues

If you're behind a corporate firewall or proxy:

```bash
# Set HTTP proxy if needed
export HTTP_PROXY=http://proxy.company.com:8080
export HTTPS_PROXY=http://proxy.company.com:8080

# Or configure git to use proxy
git config --global http.proxy http://proxy.company.com:8080
```

## Development Environment Setup

### Recommended IDE Setup

#### VS Code

Install these extensions for the best Crystal development experience:

```bash
# Install Crystal extension
code --install-extension crystal-lang.crystal

# Install Crystal Tools extension
code --install-extension crystal-lang.crystal-tools
```

#### Vim/Neovim

```bash
# Install Crystal language server
crystal install language-server

# Add to your .vimrc or init.vim
# Plug 'crystal-lang-tools/vim-crystal'
```

### Project Structure

After installation, your project should look like:

```
my-azu-app/
├── shard.yml          # Dependencies configuration
├── shard.lock         # Locked dependency versions
├── src/
│   └── my_azu_app.cr  # Main application file
├── lib/               # Installed dependencies
│   └── azu/          # Azu framework files
├── spec/              # Test files
└── .gitignore         # Git ignore rules
```

### Environment Variables

Set up environment variables for different environments:

```bash
# Development
export AZU_ENV=development
export AZU_PORT=4000

# Production
export AZU_ENV=production
export AZU_PORT=8080
export AZU_HOST=0.0.0.0
```

## Next Steps

After successful installation:

1. **[Quick Start Guide](quickstart.md)** - Get running in 5 minutes
2. **[Tutorial](tutorial.md)** - Build your first complete application
3. **[Configuration](configuration.md)** - Configure your application
4. **[Architecture Overview](../fundamentals/architecture.md)** - Understand how Azu works

## Support

If you encounter issues during installation:

- **Check the [FAQ](../resources/faq.md)** for common solutions
- **Verify Crystal installation**: `crystal version`
- **Check network connectivity**: `ping github.com`
- **Review error messages** for specific guidance

---

**Installation complete!** You're ready to start building with Azu. 🚀
