# Development Setup

Comprehensive guide to setting up a development environment for contributing to the Azu web framework.

## Overview

This guide covers everything you need to set up a development environment for contributing to Azu, including prerequisites, installation, configuration, and development tools.

## Prerequisites

### System Requirements

```bash
# Check your system requirements
echo "Operating System: $(uname -s)"
echo "Architecture: $(uname -m)"
echo "Available Memory: $(free -h | grep Mem | awk '{print $2}')"
echo "Available Disk Space: $(df -h . | tail -1 | awk '{print $4}')"
```

**Minimum Requirements:**

- **OS**: Linux, macOS, or Windows (WSL)
- **Memory**: 4GB RAM
- **Disk Space**: 2GB free space
- **Crystal**: 1.17.1 or higher

### Crystal Installation

```bash
# Install Crystal on macOS
brew install crystal

# Install Crystal on Ubuntu/Debian
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Install Crystal on CentOS/RHEL
curl -fsSL https://crystal-lang.org/install.sh | sudo bash

# Verify installation
crystal --version
```

### Git Setup

```bash
# Configure Git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Set up SSH key (optional but recommended)
ssh-keygen -t ed25519 -C "your.email@example.com"
cat ~/.ssh/id_ed25519.pub
# Add to GitHub/GitLab
```

## Repository Setup

### Fork and Clone

```bash
# Fork the repository on GitHub
# Then clone your fork
git clone https://github.com/your-username/azu.git
cd azu

# Add upstream remote
git remote add upstream https://github.com/azu-framework/azu.git

# Verify remotes
git remote -v
```

### Branch Strategy

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Or create a bugfix branch
git checkout -b fix/your-bug-description

# Or create a documentation branch
git checkout -b docs/your-doc-update
```

## Development Environment

### IDE Setup

#### VS Code Configuration

```json
// .vscode/settings.json
{
  "crystal.formatOnSave": true,
  "crystal.languageServer": true,
  "crystal.compiler": "crystal",
  "editor.formatOnSave": true,
  "editor.rulers": [120],
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true
}
```

#### VS Code Extensions

```json
// .vscode/extensions.json
{
  "recommendations": [
    "crystal-lang-tools.crystal-lang",
    "ms-vscode.vscode-json",
    "bradlc.vscode-tailwindcss",
    "esbenp.prettier-vscode"
  ]
}
```

### Crystal Language Server

```bash
# Install Crystal language server
crystal tool install

# Verify language server
crystal tool --help
```

## Project Dependencies

### Install Dependencies

```bash
# Install project dependencies
shards install

# Verify installation
crystal spec
```

### Development Dependencies

```yaml
# shard.yml development dependencies
development_dependencies:
  ameba:
    github: crystal-ameba/ameba
    version: ~> 1.5.0
  db:
    github: crystal-lang/crystal-db
    version: ~> 0.12.0
  sqlite3:
    github: crystal-lang/crystal-sqlite3
    version: ~> 0.20.0
```

## Development Tools

### Code Quality Tools

```bash
# Install Ameba for code analysis
crystal tool install ameba

# Run Ameba
crystal tool run ameba

# Run Ameba on specific files
crystal tool run ameba src/azu/
```

### Testing Setup

```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/azu/endpoint_spec.cr

# Run tests with coverage
crystal spec --coverage

# Run tests in parallel
crystal spec --parallel
```

### Documentation Generation

```bash
# Generate documentation
crystal docs

# Serve documentation locally
crystal docs --serve

# Generate API documentation
crystal docs src/azu.cr
```

## Database Setup

### Development Database

```bash
# Install PostgreSQL (macOS)
brew install postgresql
brew services start postgresql

# Install PostgreSQL (Ubuntu)
sudo apt-get install postgresql postgresql-contrib
sudo systemctl start postgresql

# Create development database
createdb azu_development
createdb azu_test
```

### Database Configuration

```crystal
# config/database.cr
CONFIG.database = {
  development: {
    url: "postgresql://localhost/azu_development",
    pool_size: 5
  },
  test: {
    url: "postgresql://localhost/azu_test",
    pool_size: 2
  }
}
```

## Development Workflow

### Code Style Guidelines

```crystal
# .editorconfig
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.cr]
indent_size = 2

[*.yml]
indent_size = 2

[*.md]
trim_trailing_whitespace = false
```

### Git Hooks

```bash
# .git/hooks/pre-commit
#!/bin/bash

# Run tests
crystal spec

# Run code analysis
crystal tool run ameba

# Check formatting
crystal tool format --check
```

### Continuous Integration

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:13
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: azu_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v3
      - name: Setup Crystal
        uses: crystal-lang/install-crystal@v1
      - name: Install dependencies
        run: shards install
      - name: Run tests
        run: crystal spec
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/azu_test
      - name: Run code analysis
        run: crystal tool run ameba
```

## Debugging Setup

### Debug Configuration

```json
// .vscode/launch.json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug Azu",
      "type": "crystal",
      "request": "launch",
      "program": "${workspaceFolder}/src/azu.cr",
      "args": [],
      "cwd": "${workspaceFolder}"
    },
    {
      "name": "Debug Tests",
      "type": "crystal",
      "request": "launch",
      "program": "crystal",
      "args": ["spec"],
      "cwd": "${workspaceFolder}"
    }
  ]
}
```

### Logging Configuration

```crystal
# config/logging.cr
require "log"

# Development logging
Log.setup do |c|
  backend = Log::IOBackend.new

  c.bind("*", :info, backend)
  c.bind("azu.*", :debug, backend)
end
```

## Performance Profiling

### Profiling Tools

```bash
# Install profiling tools
crystal tool install profile

# Run with profiling
crystal run --profile src/azu.cr

# Memory profiling
crystal run --stats src/azu.cr
```

### Benchmarking

```crystal
# spec/benchmark/performance_spec.cr
require "benchmark"

describe "Performance Benchmarks" do
  it "benchmarks endpoint performance" do
    time = Benchmark.measure do
      1000.times do
        # Test endpoint
      end
    end

    puts "Average time: #{time.real / 1000}ms"
  end
end
```

## Documentation Development

### Documentation Tools

```bash
# Install MkDocs
pip install mkdocs mkdocs-material

# Serve documentation
mkdocs serve

# Build documentation
mkdocs build
```

### Documentation Structure

```yaml
# mkdocs.yml
site_name: Azu Framework
theme:
  name: material
  features:
    - navigation.tabs
    - navigation.sections
    - navigation.expand
    - search.highlight

nav:
  - Overview: index.md
  - Getting Started:
      - Installation: getting-started/installation.md
      - First App: getting-started/first-app.md
  - Core Concepts:
      - Endpoints: core-concepts/endpoints.md
      - Requests: core-concepts/requests.md
      - Responses: core-concepts/responses.md
```

## Testing Environment

### Test Configuration

```crystal
# spec/spec_helper.cr
require "spec"
require "../src/azu"

# Test configuration
CONFIG.test = {
  database_url: "sqlite3://./test.db",
  log_level: "error",
  environment: "test"
}

# Test utilities
module TestHelpers
  def self.create_test_request(path : String, method : String = "GET")
    Azu::HttpRequest.new(
      method: method,
      path: path,
      params: {} of String => String,
      headers: HTTP::Headers.new
    )
  end
end
```

### Test Database Setup

```crystal
# spec/database_helper.cr
module DatabaseHelper
  def self.setup_test_database
    # Create test database schema
    DB.connect(CONFIG.test.database_url) do |db|
      db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
    end
  end

  def self.cleanup_test_database
    # Clean test data
    DB.connect(CONFIG.test.database_url) do |db|
      db.exec("DELETE FROM users")
    end
  end
end
```

## Development Scripts

### Build Scripts

```bash
#!/bin/bash
# scripts/build.sh

echo "Building Azu framework..."

# Clean previous build
rm -rf bin/
mkdir -p bin/

# Build release version
crystal build --release src/azu.cr -o bin/azu

# Build debug version
crystal build --debug src/azu.cr -o bin/azu-debug

echo "Build completed!"
```

### Development Server

```bash
#!/bin/bash
# scripts/dev-server.sh

echo "Starting development server..."

# Run with hot reload
crystal run --watch src/azu.cr

echo "Development server stopped."
```

### Code Quality Script

```bash
#!/bin/bash
# scripts/quality.sh

echo "Running code quality checks..."

# Format code
crystal tool format

# Run Ameba
crystal tool run ameba

# Run tests
crystal spec

echo "Code quality checks completed!"
```

## Troubleshooting

### Common Issues

```bash
# Issue: Crystal not found
export PATH="/usr/local/bin:$PATH"

# Issue: Permission denied
sudo chown -R $(whoami) /usr/local/bin

# Issue: Database connection failed
sudo systemctl start postgresql

# Issue: Dependencies not found
shards install --frozen
```

### Debug Commands

```bash
# Check Crystal installation
crystal --version
which crystal

# Check dependencies
shards list

# Check database connection
psql -h localhost -U postgres -d azu_development

# Check system resources
top
df -h
free -h
```

## Next Steps

### First Contribution

```bash
# 1. Fork the repository
# 2. Clone your fork
git clone https://github.com/your-username/azu.git

# 3. Create a feature branch
git checkout -b feature/your-feature

# 4. Make your changes
# 5. Run tests
crystal spec

# 6. Commit your changes
git add .
git commit -m "Add feature: description"

# 7. Push to your fork
git push origin feature/your-feature

# 8. Create a pull request
```

### Getting Help

- **GitHub Issues**: Report bugs and request features
- **GitHub Discussions**: Ask questions and discuss ideas
- **Discord**: Join the community chat
- **Documentation**: Read the comprehensive guides

## Best Practices

### 1. Code Organization

```crystal
# Follow the established structure
src/
├── azu/
│   ├── handler/
│   ├── templates/
│   └── *.cr
├── azu.cr
└── main.cr
```

### 2. Testing Strategy

```crystal
# Write tests for new features
describe "New Feature" do
  it "works as expected" do
    # Test implementation
  end

  it "handles edge cases" do
    # Edge case testing
  end
end
```

### 3. Documentation

```crystal
# Document public APIs
# Represents a user in the system
class User
  # Creates a new user with the given attributes
  def initialize(@name : String, @email : String)
  end
end
```

## Next Steps

- [Code Standards](standards.md) - Coding standards and guidelines
- [Roadmap](roadmap.md) - Development roadmap and priorities
- [Contributing Guidelines](contributing.md) - General contributing guidelines

---

_Happy coding! Your contributions help make Azu better for everyone._
