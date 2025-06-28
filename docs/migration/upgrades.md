# Version Upgrades

Comprehensive guide to upgrading Azu applications between versions, including breaking changes and migration strategies.

## Overview

This guide covers the process of upgrading Azu applications from one version to another, including preparation, execution, and verification steps. Each version upgrade is documented with specific changes and migration requirements.

## Upgrade Process

### Pre-Upgrade Checklist

```crystal
# Pre-upgrade verification script
# scripts/pre_upgrade_check.cr

require "azu"

class PreUpgradeCheck
  def self.run
    puts "🔍 Running pre-upgrade checks..."

    # Check current version
    current_version = Azu::VERSION
    puts "Current Azu version: #{current_version}"

    # Check compatibility
    check_crystal_version
    check_dependencies
    check_deprecated_features
    check_breaking_changes

    puts "✅ Pre-upgrade checks completed"
  end

  private def self.check_crystal_version
    required_version = "1.16.0"
    current_version = Crystal::VERSION

    if Crystal::VERSION < required_version
      puts "⚠️  Warning: Crystal #{required_version}+ required, current: #{current_version}"
    end
  end

  private def self.check_dependencies
    # Check shard dependencies
    shard_file = File.read("shard.yml")

    if shard_file.includes?("deprecated_shard")
      puts "⚠️  Warning: Using deprecated shard 'deprecated_shard'"
    end
  end

  private def self.check_deprecated_features
    # Scan codebase for deprecated features
    deprecated_patterns = [
      "Azu::DeprecatedHandler",
      "old_endpoint_pattern",
      "legacy_middleware"
    ]

    deprecated_patterns.each do |pattern|
      if File.find("src/", pattern).any?
        puts "⚠️  Warning: Found deprecated pattern: #{pattern}"
      end
    end
  end
end

PreUpgradeCheck.run
```

### Upgrade Strategy

```crystal
# Upgrade strategy configuration
# config/upgrade_strategy.cr

CONFIG.upgrade = {
  # Upgrade approach: "incremental" or "direct"
  approach: "incremental",

  # Target version
  target_version: "0.5.0",

  # Rollback configuration
  rollback_enabled: true,
  rollback_version: "0.4.14",

  # Testing configuration
  run_tests_after_upgrade: true,
  test_coverage_threshold: 80
}
```

## Version-Specific Upgrades

### Upgrading to v0.5.0

#### Breaking Changes

```crystal
# v0.4.14 -> v0.5.0 breaking changes

# 1. Handler interface changes
# OLD (v0.4.14)
class OldHandler
  def call(request, response)
    # Old interface
  end
end

# NEW (v0.5.0)
class NewHandler
  include Azu::Handler

  def call(request, response)
    # New interface with proper typing
  end
end
```

#### Migration Steps

```crystal
# Migration script for v0.5.0
# scripts/migrate_to_v0_5_0.cr

class V050Migration
  def self.migrate
    puts "🚀 Migrating to Azu v0.5.0..."

    # Step 1: Update shard.yml
    update_shard_yml

    # Step 2: Update handler implementations
    update_handlers

    # Step 3: Update endpoint patterns
    update_endpoints

    # Step 4: Update configuration
    update_configuration

    # Step 5: Run tests
    run_tests

    puts "✅ Migration to v0.5.0 completed"
  end

  private def self.update_shard_yml
    shard_content = File.read("shard.yml")
    updated_content = shard_content.gsub(
      /azu:\s*0\.4\.\d+/,
      "azu: 0.5.0"
    )
    File.write("shard.yml", updated_content)
  end

  private def self.update_handlers
    # Update handler files
    Dir.glob("src/**/*_handler.cr").each do |file|
      content = File.read(file)

      # Add Handler include
      unless content.includes?("include Azu::Handler")
        content = content.gsub(
          /class (\w+Handler)/,
          "class \\1\n  include Azu::Handler"
        )
      end

      File.write(file, content)
    end
  end

  private def self.update_endpoints
    # Update endpoint patterns
    Dir.glob("src/**/*_endpoint.cr").each do |file|
      content = File.read(file)

      # Update endpoint include pattern
      content = content.gsub(
        /include Endpoint\(([^,]+), ([^)]+)\)/,
        "include Endpoint(\\1, \\2)"
      )

      File.write(file, content)
    end
  end
end
```

### Upgrading to v0.4.14

#### New Features

```crystal
# v0.4.13 -> v0.4.14 new features

# 1. Enhanced WebSocket support
class EnhancedChannel < Azu::Channel
  ws "/enhanced"

  # New: Automatic reconnection
  def on_connect
    @auto_reconnect = true
    @reconnect_interval = 5.seconds
  end

  # New: Message validation
  def validate_message(message) : Bool
    message.size > 0 && message.size < 1000
  end
end

# 2. Improved error handling
struct ErrorResponse
  include Response

  def initialize(@error : Exception, @context : Hash(String, String) = {} of String => String)
  end

  def render
    {
      error: @error.message,
      type: @error.class.name,
      context: @context,
      timestamp: Time.utc
    }.to_json
  end
end
```

#### Migration Steps

```crystal
# Migration script for v0.4.14
# scripts/migrate_to_v0_4_14.cr

class V0414Migration
  def self.migrate
    puts "🚀 Migrating to Azu v0.4.14..."

    # Step 1: Update dependencies
    update_dependencies

    # Step 2: Enable new features
    enable_new_features

    # Step 3: Update error handling
    update_error_handling

    puts "✅ Migration to v0.4.14 completed"
  end

  private def self.update_dependencies
    # Update shard.yml
    shard_content = File.read("shard.yml")
    updated_content = shard_content.gsub(
      /azu:\s*0\.4\.\d+/,
      "azu: 0.4.14"
    )
    File.write("shard.yml", updated_content)
  end

  private def self.enable_new_features
    # Enable WebSocket auto-reconnection
    Dir.glob("src/**/*_channel.cr").each do |file|
      content = File.read(file)

      unless content.includes?("@auto_reconnect")
        content = content.gsub(
          /def on_connect/,
          "def on_connect\n    @auto_reconnect = true"
        )
      end

      File.write(file, content)
    end
  end
end
```

## Automated Migration Tools

### Migration Generator

```crystal
# Migration generator
# scripts/generate_migration.cr

class MigrationGenerator
  def self.generate(from_version : String, to_version : String)
    puts "🔧 Generating migration from #{from_version} to #{to_version}..."

    # Create migration file
    migration_file = "migrations/#{from_version}_to_#{to_version}.cr"

    migration_content = <<-CRYSTAL
      # Migration: #{from_version} -> #{to_version}
      # Generated on: #{Time.utc}

      class #{from_version.capitalize}To#{to_version.capitalize}Migration
        def self.migrate
          puts "🚀 Migrating from #{from_version} to #{to_version}..."

          # TODO: Add migration steps

          puts "✅ Migration completed"
        end

        def self.rollback
          puts "🔄 Rolling back from #{to_version} to #{from_version}..."

          # TODO: Add rollback steps

          puts "✅ Rollback completed"
        end
      end
      CRYSTAL

    File.write(migration_file, migration_content)
    puts "📝 Generated migration file: #{migration_file}"
  end
end
```

### Migration Runner

```crystal
# Migration runner
# scripts/run_migration.cr

class MigrationRunner
  def self.run(migration_file : String)
    puts "🏃 Running migration: #{migration_file}"

    # Load and run migration
    require migration_file

    migration_class = get_migration_class(migration_file)
    migration_class.migrate

    puts "✅ Migration completed successfully"
  rescue ex
    puts "❌ Migration failed: #{ex.message}"
    puts "🔄 Starting rollback..."

    migration_class = get_migration_class(migration_file)
    migration_class.rollback

    raise ex
  end

  private def self.get_migration_class(file_path : String) : Class
    # Extract class name from file path
    class_name = File.basename(file_path, ".cr").split("_").map(&.capitalize).join
    Object.const_get(class_name)
  end
end
```

## Testing Upgrades

### Upgrade Testing Strategy

```crystal
# Upgrade testing configuration
# spec/upgrade/upgrade_spec.cr

require "../spec_helper"

describe "Upgrade Compatibility" do
  describe "v0.4.14 -> v0.5.0" do
    it "maintains API compatibility" do
      # Test that existing endpoints still work
      endpoints = [
        UserEndpoint,
        PostEndpoint,
        CommentEndpoint
      ]

      endpoints.each do |endpoint_class|
        endpoint = endpoint_class.new
        endpoint.should respond_to(:call)
      end
    end

    it "handles new features correctly" do
      # Test new features introduced in upgrade
      new_handler = NewHandler.new
      new_handler.should be_a(Azu::Handler)
    end

    it "maintains performance characteristics" do
      # Benchmark before and after upgrade
      before_performance = benchmark_endpoint(UserEndpoint)
      after_performance = benchmark_endpoint(UserEndpoint)

      # Performance should not degrade significantly
      performance_ratio = after_performance / before_performance
      performance_ratio.should be >= 0.95
    end
  end
end
```

### Regression Testing

```crystal
# Regression testing script
# scripts/regression_test.cr

class RegressionTest
  def self.run
    puts "🧪 Running regression tests..."

    # Run all existing tests
    system("crystal spec")

    # Run specific upgrade tests
    run_upgrade_specific_tests

    # Run performance tests
    run_performance_tests

    # Run integration tests
    run_integration_tests

    puts "✅ Regression tests completed"
  end

  private def self.run_upgrade_specific_tests
    # Test specific features that might be affected by upgrade
    test_endpoints
    test_handlers
    test_websockets
    test_templates
  end

  private def self.run_performance_tests
    # Benchmark critical paths
    benchmark_user_creation
    benchmark_post_retrieval
    benchmark_websocket_connections
  end
end
```

## Rollback Procedures

### Automatic Rollback

```crystal
# Rollback configuration
# config/rollback.cr

CONFIG.rollback = {
  enabled: true,
  automatic: true,
  triggers: [
    "test_failure",
    "performance_degradation",
    "critical_error"
  ],
  backup_strategy: "git_tag",
  rollback_timeout: 5.minutes
}

# Rollback handler
class RollbackHandler
  def self.trigger_rollback(reason : String)
    puts "🔄 Triggering rollback: #{reason}"

    # Create backup
    create_backup

    # Revert to previous version
    revert_version

    # Restart application
    restart_application

    puts "✅ Rollback completed"
  end

  private def self.create_backup
    timestamp = Time.utc.to_s("%Y%m%d_%H%M%S")
    system("git tag backup_#{timestamp}")
  end

  private def self.revert_version
    system("git checkout #{CONFIG.rollback.previous_version}")
    system("shards install")
  end
end
```

### Manual Rollback

```crystal
# Manual rollback script
# scripts/manual_rollback.cr

class ManualRollback
  def self.rollback_to(version : String)
    puts "🔄 Manual rollback to version #{version}..."

    # Step 1: Stop application
    stop_application

    # Step 2: Revert code
    revert_code(version)

    # Step 3: Update dependencies
    update_dependencies(version)

    # Step 4: Restart application
    restart_application

    # Step 5: Verify rollback
    verify_rollback

    puts "✅ Manual rollback completed"
  end

  private def self.stop_application
    system("pkill -f azu_app")
  end

  private def self.revert_code(version)
    system("git checkout #{version}")
  end

  private def self.update_dependencies(version)
    # Update shard.yml to target version
    shard_content = File.read("shard.yml")
    updated_content = shard_content.gsub(
      /azu:\s*[\d\.]+/,
      "azu: #{version}"
    )
    File.write("shard.yml", updated_content)

    system("shards install")
  end
end
```

## Version Compatibility Matrix

### Compatibility Table

```crystal
# Version compatibility matrix
COMPATIBILITY_MATRIX = {
  "0.5.0" => {
    "crystal": ">= 1.16.0",
    "dependencies": {
      "radix": ">= 0.4.0",
      "schema": ">= 0.1.0",
      "crinja": ">= 0.2.0"
    },
    "breaking_changes": [
      "Handler interface changes",
      "Endpoint pattern updates",
      "Configuration structure changes"
    ]
  },
  "0.4.14" => {
    "crystal": ">= 1.15.0",
    "dependencies": {
      "radix": ">= 0.3.0",
      "schema": ">= 0.1.0",
      "crinja": ">= 0.1.0"
    },
    "breaking_changes": [
      "WebSocket API changes",
      "Error handling updates"
    ]
  }
}
```

## Best Practices

### 1. Incremental Upgrades

```crystal
# Incremental upgrade strategy
class IncrementalUpgrade
  def self.upgrade_to(target_version : String)
    current_version = Azu::VERSION
    versions = get_upgrade_path(current_version, target_version)

    versions.each do |version|
      puts "🔄 Upgrading to #{version}..."

      # Run migration for this version
      run_migration(version)

      # Run tests
      run_tests(version)

      # Verify functionality
      verify_functionality(version)

      puts "✅ Successfully upgraded to #{version}"
    end
  end
end
```

### 2. Backup Strategy

```crystal
# Backup strategy
class BackupStrategy
  def self.create_backup
    timestamp = Time.utc.to_s("%Y%m%d_%H%M%S")

    # Git backup
    system("git tag backup_#{timestamp}")

    # Database backup
    create_database_backup(timestamp)

    # Configuration backup
    create_config_backup(timestamp)

    puts "💾 Backup created: backup_#{timestamp}"
  end

  private def self.create_database_backup(timestamp)
    # Create database dump
    system("pg_dump myapp > backup_db_#{timestamp}.sql")
  end
end
```

### 3. Monitoring During Upgrade

```crystal
# Upgrade monitoring
class UpgradeMonitor
  def self.monitor_upgrade
    puts "📊 Monitoring upgrade process..."

    # Monitor application health
    monitor_health

    # Monitor performance
    monitor_performance

    # Monitor errors
    monitor_errors

    # Monitor user experience
    monitor_user_experience
  end

  private def self.monitor_health
    # Check application status
    health_check = HTTP::Client.get("http://localhost:3000/health")

    if health_check.status_code != 200
      puts "⚠️  Health check failed"
      RollbackHandler.trigger_rollback("health_check_failed")
    end
  end
end
```

## Troubleshooting

### Common Upgrade Issues

```crystal
# Common upgrade issues and solutions
UPGRADE_ISSUES = {
  "handler_interface_error" => {
    "symptom": "Handler interface not found",
    "solution": "Add 'include Azu::Handler' to handler classes",
    "code_fix": "class MyHandler\n  include Azu::Handler\n  # ..."
  },
  "endpoint_pattern_error" => {
    "symptom": "Endpoint pattern not recognized",
    "solution": "Update endpoint include pattern",
    "code_fix": "include Endpoint(MyRequest, MyResponse)"
  },
  "dependency_conflict" => {
    "symptom": "Shard dependency conflicts",
    "solution": "Update shard.yml and run 'shards update'",
    "code_fix": "shards update"
  }
}
```

### Debug Tools

```crystal
# Upgrade debug tools
class UpgradeDebug
  def self.diagnose_issues
    puts "🔍 Diagnosing upgrade issues..."

    # Check for common issues
    check_handler_issues
    check_endpoint_issues
    check_dependency_issues
    check_configuration_issues

    # Generate report
    generate_diagnostic_report
  end

  private def self.check_handler_issues
    Dir.glob("src/**/*_handler.cr").each do |file|
      content = File.read(file)

      unless content.includes?("include Azu::Handler")
        puts "⚠️  Handler missing include: #{file}"
      end
    end
  end
end
```

## Next Steps

- [Breaking Changes](breaking-changes.md) - Detailed breaking changes documentation
- [Migration Best Practices](migration.md) - General migration guidelines
- [Version Compatibility](migration.md) - Compatibility information

---

_Always test upgrades in a staging environment before applying to production._
