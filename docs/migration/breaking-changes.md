# Breaking Changes

Comprehensive documentation of breaking changes between Azu versions, including migration guides and compatibility information.

## Overview

This document provides detailed information about breaking changes introduced in each Azu version. Breaking changes are modifications that may cause existing code to fail or behave differently, requiring updates to maintain compatibility.

## Version 0.5.0 Breaking Changes

### Handler Interface Changes

#### Before (v0.4.14)

```crystal
# Old handler pattern
class OldHandler
  def call(request, response)
    # Handler implementation
    @next.call(request, response)
  end
end
```

#### After (v0.5.0)

```crystal
# New handler pattern
class NewHandler
  include Azu::Handler

  def call(request : Azu::HttpRequest, response : Azu::Response) : Azu::Response
    # Handler implementation with proper typing
    @next.call(request, response)
  end
end
```

#### Migration Guide

```crystal
# Migration script for handler interface
class HandlerMigration
  def self.migrate_handlers
    Dir.glob("src/**/*_handler.cr").each do |file|
      content = File.read(file)

      # Add Handler include
      unless content.includes?("include Azu::Handler")
        content = content.gsub(
          /class (\w+Handler)/,
          "class \\1\n  include Azu::Handler"
        )
      end

      # Update method signature
      content = content.gsub(
        /def call\(request, response\)/,
        "def call(request : Azu::HttpRequest, response : Azu::Response) : Azu::Response"
      )

      File.write(file, content)
    end
  end
end
```

### Endpoint Pattern Updates

#### Before (v0.4.14)

```crystal
# Old endpoint pattern
struct OldEndpoint
  include Endpoint(OldRequest, OldResponse)

  get "/old-pattern"

  def call
    # Implementation
  end
end
```

#### After (v0.5.0)

```crystal
# New endpoint pattern
struct NewEndpoint
  include Endpoint(NewRequest, NewResponse)

  get "/new-pattern"

  def call : NewResponse
    # Implementation with explicit return type
  end
end
```

#### Migration Guide

```crystal
# Migration script for endpoint patterns
class EndpointMigration
  def self.migrate_endpoints
    Dir.glob("src/**/*_endpoint.cr").each do |file|
      content = File.read(file)

      # Update call method signature
      content = content.gsub(
        /def call$/,
        "def call : #{get_response_type(content)}"
      )

      File.write(file, content)
    end
  end

  private def self.get_response_type(content : String) : String
    # Extract response type from Endpoint include
    if match = content.match(/include Endpoint\([^,]+,\s*([^)]+)\)/)
      match[1]
    else
      "Azu::Response"
    end
  end
end
```

### Configuration Structure Changes

#### Before (v0.4.14)

```crystal
# Old configuration
CONFIG = {
  port: 3000,
  host: "localhost",
  environment: "development"
}
```

#### After (v0.5.0)

```crystal
# New configuration structure
CONFIG = Azu::Configuration.new(
  port: 3000,
  host: "localhost",
  environment: "development"
)
```

#### Migration Guide

```crystal
# Migration script for configuration
class ConfigurationMigration
  def self.migrate_configuration
    config_files = ["config/application.cr", "src/config.cr"]

    config_files.each do |file|
      next unless File.exists?(file)

      content = File.read(file)

      # Update configuration initialization
      content = content.gsub(
        /CONFIG\s*=\s*\{/,
        "CONFIG = Azu::Configuration.new("
      )

      content = content.gsub(
        /\}$/,
        ")"
      )

      File.write(file, content)
    end
  end
end
```

## Version 0.4.14 Breaking Changes

### WebSocket API Changes

#### Before (v0.4.13)

```crystal
# Old WebSocket channel
class OldChannel < Azu::Channel
  ws "/old-websocket"

  def on_message(message)
    # Old message handling
  end
end
```

#### After (v0.4.14)

```crystal
# New WebSocket channel
class NewChannel < Azu::Channel
  ws "/new-websocket"

  def on_message(message : String)
    # New message handling with type safety
  end

  def on_connect
    # New connection handling
  end

  def on_disconnect
    # New disconnection handling
  end
end
```

#### Migration Guide

```crystal
# Migration script for WebSocket channels
class WebSocketMigration
  def self.migrate_channels
    Dir.glob("src/**/*_channel.cr").each do |file|
      content = File.read(file)

      # Add type annotation to on_message
      content = content.gsub(
        /def on_message\(message\)/,
        "def on_message(message : String)"
      )

      # Add on_connect and on_disconnect if missing
      unless content.includes?("def on_connect")
        content += "\n  def on_connect\n    # Connection handling\n  end\n"
      end

      unless content.includes?("def on_disconnect")
        content += "\n  def on_disconnect\n    # Disconnection handling\n  end\n"
      end

      File.write(file, content)
    end
  end
end
```

### Error Handling Updates

#### Before (v0.4.13)

```crystal
# Old error handling
class OldErrorHandler
  def handle_error(error)
    # Old error handling
  end
end
```

#### After (v0.4.14)

```crystal
# New error handling
class NewErrorHandler
  include Azu::Handler

  def call(request, response)
    @next.call(request, response)
  rescue ex : Exception
    handle_error(ex, request, response)
  end

  private def handle_error(error : Exception, request : Azu::HttpRequest, response : Azu::Response)
    # New error handling with context
  end
end
```

#### Migration Guide

```crystal
# Migration script for error handling
class ErrorHandlingMigration
  def self.migrate_error_handlers
    Dir.glob("src/**/*error*.cr").each do |file|
      content = File.read(file)

      # Update error handler pattern
      content = content.gsub(
        /def handle_error\(error\)/,
        "def handle_error(error : Exception, request : Azu::HttpRequest, response : Azu::Response)"
      )

      File.write(file, content)
    end
  end
end
```

## Version 0.4.13 Breaking Changes

### Request/Response Interface Changes

#### Before (v0.4.12)

```crystal
# Old request/response pattern
struct OldRequest
  getter params : Hash(String, String)
end

struct OldResponse
  def initialize(@body : String)
  end
end
```

#### After (v0.4.13)

```crystal
# New request/response pattern
struct NewRequest
  include Azu::Request

  getter params : Azu::Params
  getter headers : HTTP::Headers
end

struct NewResponse
  include Azu::Response

  def initialize(@body : String, @status : Int32 = 200)
  end

  def render : String
    @body
  end
end
```

#### Migration Guide

```crystal
# Migration script for request/response
class RequestResponseMigration
  def self.migrate_requests
    Dir.glob("src/**/*_request.cr").each do |file|
      content = File.read(file)

      # Add Request include
      unless content.includes?("include Azu::Request")
        content = content.gsub(
          /struct (\w+Request)/,
          "struct \\1\n  include Azu::Request"
        )
      end

      # Update params type
      content = content.gsub(
        /getter params : Hash\(String, String\)/,
        "getter params : Azu::Params"
      )

      File.write(file, content)
    end
  end

  def self.migrate_responses
    Dir.glob("src/**/*_response.cr").each do |file|
      content = File.read(file)

      # Add Response include
      unless content.includes?("include Azu::Response")
        content = content.gsub(
          /struct (\w+Response)/,
          "struct \\1\n  include Azu::Response"
        )
      end

      # Add render method if missing
      unless content.includes?("def render")
        content += "\n  def render : String\n    @body\n  end\n"
      end

      File.write(file, content)
    end
  end
end
```

## Version 0.4.12 Breaking Changes

### Middleware Registration Changes

#### Before (v0.4.11)

```crystal
# Old middleware registration
app = ExampleApp.new
app.use OldMiddleware.new
app.use AnotherMiddleware.new
```

#### After (v0.4.12)

```crystal
# New middleware registration
app = ExampleApp.new([
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new
])
```

#### Migration Guide

```crystal
# Migration script for middleware
class MiddlewareMigration
  def self.migrate_middleware
    app_files = ["src/app.cr", "src/example_app.cr"]

    app_files.each do |file|
      next unless File.exists?(file)

      content = File.read(file)

      # Update middleware registration pattern
      content = content.gsub(
        /app\.use\s+(\w+)\.new/,
        "Azu::Handler::\\1.new"
      )

      # Update app initialization
      content = content.gsub(
        /app\s*=\s*(\w+)\.new/,
        "app = \\1.new(["
      )

      content = content.gsub(
        /app\.start/,
        "])"
      )

      File.write(file, content)
    end
  end
end
```

## Compatibility Matrix

### Version Compatibility Table

```crystal
# Version compatibility matrix
COMPATIBILITY_MATRIX = {
  "0.5.0" => {
    "crystal": ">= 1.16.0",
    "breaking_changes": [
      "Handler interface requires Azu::Handler include",
      "Endpoint call methods require explicit return types",
      "Configuration uses Azu::Configuration class"
    ],
    "migration_required": true,
    "estimated_migration_time": "2-4 hours"
  },
  "0.4.14" => {
    "crystal": ">= 1.15.0",
    "breaking_changes": [
      "WebSocket on_message requires String type annotation",
      "WebSocket channels require on_connect/on_disconnect methods",
      "Error handlers require request/response context"
    ],
    "migration_required": true,
    "estimated_migration_time": "1-2 hours"
  },
  "0.4.13" => {
    "crystal": ">= 1.15.0",
    "breaking_changes": [
      "Request objects require Azu::Request include",
      "Response objects require Azu::Response include and render method",
      "Params type changed from Hash to Azu::Params"
    ],
    "migration_required": true,
    "estimated_migration_time": "1-3 hours"
  },
  "0.4.12" => {
    "crystal": ">= 1.14.0",
    "breaking_changes": [
      "Middleware registration pattern changed",
      "App initialization requires handler array"
    ],
    "migration_required": true,
    "estimated_migration_time": "30 minutes"
  }
}
```

## Migration Tools

### Automated Migration Script

```crystal
# Comprehensive migration script
# scripts/migrate_all.cr

class ComprehensiveMigration
  def self.migrate_all(from_version : String, to_version : String)
    puts "🚀 Starting comprehensive migration from #{from_version} to #{to_version}..."

    # Create backup
    create_backup

    # Run version-specific migrations
    case {from_version, to_version}
    when {"0.4.14", "0.5.0"}
      migrate_to_v050
    when {"0.4.13", "0.4.14"}
      migrate_to_v0414
    when {"0.4.12", "0.4.13"}
      migrate_to_v0413
    when {"0.4.11", "0.4.12"}
      migrate_to_v0412
    else
      puts "⚠️  No direct migration path available"
      puts "Consider upgrading incrementally"
    end

    # Update dependencies
    update_dependencies(to_version)

    # Run tests
    run_tests

    puts "✅ Migration completed successfully"
  end

  private def self.migrate_to_v050
    HandlerMigration.migrate_handlers
    EndpointMigration.migrate_endpoints
    ConfigurationMigration.migrate_configuration
  end

  private def self.migrate_to_v0414
    WebSocketMigration.migrate_channels
    ErrorHandlingMigration.migrate_error_handlers
  end

  private def self.migrate_to_v0413
    RequestResponseMigration.migrate_requests
    RequestResponseMigration.migrate_responses
  end

  private def self.migrate_to_v0412
    MiddlewareMigration.migrate_middleware
  end
end
```

### Migration Validation

```crystal
# Migration validation script
# scripts/validate_migration.cr

class MigrationValidator
  def self.validate_migration
    puts "🔍 Validating migration..."

    # Check for common issues
    check_handler_includes
    check_endpoint_patterns
    check_configuration_structure
    check_websocket_channels
    check_error_handlers

    # Generate validation report
    generate_validation_report

    puts "✅ Migration validation completed"
  end

  private def self.check_handler_includes
    Dir.glob("src/**/*_handler.cr").each do |file|
      content = File.read(file)

      unless content.includes?("include Azu::Handler")
        puts "❌ Handler missing include: #{file}"
      end
    end
  end

  private def self.check_endpoint_patterns
    Dir.glob("src/**/*_endpoint.cr").each do |file|
      content = File.read(file)

      unless content.includes?("def call :")
        puts "❌ Endpoint missing return type: #{file}"
      end
    end
  end
end
```

## Testing Breaking Changes

### Breaking Change Tests

```crystal
# Breaking change test suite
# spec/breaking_changes/breaking_changes_spec.cr

require "../spec_helper"

describe "Breaking Changes" do
  describe "v0.4.14 -> v0.5.0" do
    it "validates handler interface compliance" do
      # Test that all handlers include Azu::Handler
      handler_classes = [
        CustomHandler,
        AuthHandler,
        LoggingHandler
      ]

      handler_classes.each do |handler_class|
        handler = handler_class.new
        handler.should be_a(Azu::Handler)
      end
    end

    it "validates endpoint return types" do
      # Test that all endpoints have explicit return types
      endpoint_classes = [
        UserEndpoint,
        PostEndpoint,
        CommentEndpoint
      ]

      endpoint_classes.each do |endpoint_class|
        endpoint = endpoint_class.new
        method = endpoint.class.methods.find { |m| m.name == "call" }
        method.should_not be_nil
        method.not_nil!.return_type.should_not be_nil
      end
    end
  end
end
```

## Rollback Procedures

### Breaking Change Rollback

```crystal
# Rollback script for breaking changes
# scripts/rollback_breaking_changes.cr

class BreakingChangeRollback
  def self.rollback_to(version : String)
    puts "🔄 Rolling back breaking changes to version #{version}..."

    # Stop application
    stop_application

    # Revert code changes
    revert_code_changes(version)

    # Revert dependencies
    revert_dependencies(version)

    # Restart application
    restart_application

    # Verify rollback
    verify_rollback

    puts "✅ Breaking change rollback completed"
  end

  private def self.revert_code_changes(version)
    case version
    when "0.4.14"
      revert_v050_changes
    when "0.4.13"
      revert_v0414_changes
    when "0.4.12"
      revert_v0413_changes
    end
  end

  private def self.revert_v050_changes
    # Revert handler interface changes
    Dir.glob("src/**/*_handler.cr").each do |file|
      content = File.read(file)
      content = content.gsub("include Azu::Handler\n  ", "")
      content = content.gsub("def call(request : Azu::HttpRequest, response : Azu::Response) : Azu::Response", "def call(request, response)")
      File.write(file, content)
    end
  end
end
```

## Best Practices

### 1. Incremental Migration

```crystal
# Incremental migration strategy
class IncrementalMigration
  def self.migrate_incrementally(target_version : String)
    current_version = Azu::VERSION
    versions = get_migration_path(current_version, target_version)

    versions.each do |version|
      puts "🔄 Migrating to #{version}..."

      # Run migration for this version
      run_version_migration(version)

      # Test thoroughly
      run_comprehensive_tests(version)

      # Commit changes
      commit_migration(version)

      puts "✅ Successfully migrated to #{version}"
    end
  end
end
```

### 2. Comprehensive Testing

```crystal
# Comprehensive testing strategy
class ComprehensiveTesting
  def self.test_after_migration
    puts "🧪 Running comprehensive tests after migration..."

    # Run unit tests
    system("crystal spec spec/unit/")

    # Run integration tests
    system("crystal spec spec/integration/")

    # Run breaking change tests
    system("crystal spec spec/breaking_changes/")

    # Run performance tests
    system("crystal spec spec/performance/")

    # Run WebSocket tests
    system("crystal spec spec/websocket/")

    puts "✅ Comprehensive testing completed"
  end
end
```

### 3. Documentation Updates

```crystal
# Documentation update script
# scripts/update_documentation.cr

class DocumentationUpdater
  def self.update_documentation(version : String)
    puts "📝 Updating documentation for version #{version}..."

    # Update README
    update_readme(version)

    # Update API documentation
    update_api_docs(version)

    # Update migration guides
    update_migration_guides(version)

    # Update examples
    update_examples(version)

    puts "✅ Documentation updated"
  end
end
```

## Next Steps

- [Version Upgrades](upgrades.md) - Complete upgrade process guide
- [Migration Best Practices](migration.md) - General migration guidelines
- [Testing Breaking Changes](testing.md) - Testing strategies for breaking changes

---

_Always test breaking changes thoroughly in a staging environment before applying to production._
