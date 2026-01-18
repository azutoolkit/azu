# Azu Framework - Implementation Strategy Guide

This document outlines how Claude should approach adding new features to the Azu framework while maintaining its performance and safety guarantees.

## Core Principles

### 1. Type Safety First

Every new feature must leverage Crystal's type system:

- Define explicit types for all public interfaces
- Use generics for flexible, type-safe abstractions
- Prefer compile-time errors over runtime errors

### 2. Performance by Design

Azu follows "fast as C, slick as Ruby":

- Minimize allocations in hot paths
- Use structs for value objects
- Consider compile-time conditionals for optional features
- Benchmark critical paths before and after changes

### 3. Backward Compatibility

- Existing APIs should not break
- Deprecate before removing
- Provide migration paths for breaking changes

---

## Step-by-Step Implementation Workflow

### Phase 1: Discovery & Planning

#### 1.1 Understand the Feature Request

```
Questions to answer:
- What problem does this solve?
- Who uses this feature?
- What are the expected inputs/outputs?
- Are there performance requirements?
```

#### 1.2 Research Existing Patterns

```bash
# Search for similar patterns in codebase
grep -r "pattern_keyword" src/azu/
```

Check these locations:

- `src/azu/` - Core modules for architectural patterns
- `playground/` - Example implementations
- `docs/` - Existing documentation
- `spec/` - Test patterns

#### 1.3 Design the Interface

Before writing code, design:

1. **Public API** - Method signatures, types, return values
2. **Configuration** - How is the feature configured?
3. **Error Handling** - What can go wrong? How to report?
4. **Integration Points** - How does it fit with existing modules?

#### 1.4 Create Implementation Plan

Document in a comment or issue:

```
Feature: [Name]
Files to create/modify:
- [ ] src/azu/new_feature.cr - Core implementation
- [ ] src/azu/handler/new_handler.cr - Middleware (if needed)
- [ ] spec/azu/new_feature_spec.cr - Unit tests
- [ ] spec/integration/new_feature_spec.cr - Integration tests
- [ ] docs/guide/new_feature.md - Documentation

Dependencies: [List any new shards]
Breaking changes: [None / List if any]
```

---

### Phase 2: Implementation

#### 2.1 Start with Types

Define the core types first:

```crystal
# src/azu/new_feature.cr

module Azu
  # Document the purpose
  module NewFeature
    # Configuration type
    struct Config
      getter enabled : Bool
      getter option : String

      def initialize(@enabled = true, @option = "default")
      end
    end

    # Main interface
    abstract def process(input : Input) : Output
  end
end
```

#### 2.2 Implement Core Logic

Follow these patterns:

**For Request/Response handling:**

```crystal
struct NewFeatureRequest
  include Azu::Request

  @required_field : String

  validate required_field, presence: true
end

struct NewFeatureResponse
  include Azu::Response

  def render
    # Type-safe rendering
  end
end
```

**For Middleware:**

```crystal
class NewHandler < Azu::Handler::Base
  def call(context : HTTP::Server::Context)
    # Pre-processing
    before_action(context)

    # Continue chain
    call_next(context)

    # Post-processing
    after_action(context)
  rescue ex
    handle_error(context, ex)
  end
end
```

**For Components:**

```crystal
class NewComponent
  include Azu::Component

  def content
    div do
      # Markup building
    end
  end

  def on_event(event : String, payload : JSON::Any)
    # Event handling
  end
end
```

#### 2.3 Thread Safety Requirements

If the feature involves shared state:

```crystal
class StatefulFeature
  @mutex = Mutex.new
  @data = {} of String => Value

  def read(key : String) : Value?
    @mutex.synchronize { @data[key]? }
  end

  def write(key : String, value : Value)
    @mutex.synchronize { @data[key] = value }
  end
end
```

#### 2.4 Error Handling

Create appropriate error types:

```crystal
module Azu::Response
  class NewFeatureError < Error
    def initialize(message : String, context : ErrorContext? = nil)
      super(message, 400, context)  # Choose appropriate status code
    end
  end
end
```

---

### Phase 3: Testing

#### 3.1 Unit Tests

Test individual components in isolation:

```crystal
# spec/azu/new_feature_spec.cr

describe Azu::NewFeature do
  describe "#process" do
    it "handles valid input" do
      feature = NewFeature.new
      result = feature.process(valid_input)
      result.should be_a(ExpectedOutput)
    end

    it "raises error for invalid input" do
      feature = NewFeature.new
      expect_raises(NewFeatureError) do
        feature.process(invalid_input)
      end
    end
  end
end
```

#### 3.2 Integration Tests

Test the feature in the full request cycle:

```crystal
# spec/integration/new_feature_spec.cr

describe "NewFeature Integration" do
  before_all { spawn_server }
  after_all { kill_server }

  it "works end-to-end" do
    response = HTTP::Client.post(
      "http://localhost:4000/new-feature",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {data: "test"}.to_json
    )

    response.status_code.should eq 200
    # Verify response content
  end
end
```

#### 3.3 Performance Tests

For performance-critical features:

```crystal
# spec/integration/performance_spec.cr

it "handles 1000 requests efficiently" do
  start = Time.monotonic

  1000.times do
    HTTP::Client.get("http://localhost:4000/new-feature")
  end

  duration = Time.monotonic - start
  duration.should be < 1.second  # Adjust threshold as needed
end
```

---

### Phase 4: Documentation

#### 4.1 Code Documentation

Add doc comments to all public methods:

````crystal
# Processes the input and returns the transformed output.
#
# The processing applies [describe algorithm/transformation].
#
# ```
# feature = NewFeature.new
# result = feature.process(Input.new("data"))
# result.value # => "processed_data"
# ```
#
# Raises `NewFeatureError` if the input is malformed.
def process(input : Input) : Output
end
````

#### 4.2 Guide Documentation

Create or update docs:

```markdown
<!-- docs/guide/new_feature.md -->

# New Feature Guide

## Overview

[Explain what the feature does and why]

## Quick Start

[Show minimal working example]

## Configuration

[Document all options]

## Examples

[Provide common use cases]

## API Reference

[Link to generated docs]
```

---

### Phase 5: Integration

#### 5.1 Update Configuration

If the feature is configurable:

```crystal
# src/azu/configuration.cr

class Configuration
  property new_feature : NewFeature::Config = NewFeature::Config.new

  # Add to configure block
end
```

#### 5.2 Register with Router (if endpoint)

```crystal
# Endpoint auto-registers via macro
struct NewFeatureEndpoint
  include Azu::Endpoint(NewFeatureRequest, NewFeatureResponse)

  post "/new-feature"

  def call : NewFeatureResponse
    # Implementation
  end
end
```

#### 5.3 Add to Handler Chain (if middleware)

```crystal
# In application startup
Azu.configure do |config|
  config.handlers << NewHandler.new
end
```

---

## Safety Checklist

Before submitting changes, verify:

### Type Safety

- [ ] All public methods have explicit return types
- [ ] Generic constraints are properly defined
- [ ] Nil is handled explicitly (no implicit `.not_nil!`)
- [ ] Union types are minimized

### Thread Safety

- [ ] Shared mutable state uses Mutex or Atomic
- [ ] No global variables modified at runtime
- [ ] Fiber-safe data structures used

### Performance

- [ ] No unnecessary allocations in hot paths
- [ ] Structs used for value objects
- [ ] Caching considered where appropriate
- [ ] Benchmarks show acceptable performance

### Error Handling

- [ ] Custom error types inherit from appropriate base
- [ ] Error context is propagated
- [ ] User-facing errors are clear
- [ ] Errors are logged appropriately

### Testing

- [ ] Unit tests cover main functionality
- [ ] Edge cases are tested
- [ ] Integration tests verify full cycle
- [ ] Tests run in CI

### Documentation

- [ ] Public APIs documented
- [ ] Examples provided
- [ ] Guide updated if needed

---

## Common Patterns Reference

### Adding a New Endpoint Type

1. Create request struct with validations
2. Create response struct with render method
3. Create endpoint with HTTP method macro
4. Add tests in unit and integration suites

### Adding Middleware

1. Create handler in `src/azu/handler/`
2. Implement `call(context)` with chain propagation
3. Add error handling
4. Document configuration options
5. Add to handler registry

### Adding a Cache Strategy

1. Implement `CacheStore` interface
2. Add to store factory
3. Add configuration option
4. Document usage

### Adding a Component Type

1. Include `Azu::Component`
2. Implement `content` method
3. Add event handlers with `on_event`
4. Register with Spark system if real-time

---

## Performance Optimization Guide

### Profiling

```crystal
# Enable performance monitoring
{% if env("PERFORMANCE_MONITORING") == "true" %}
  require "./performance_metrics"
{% end %}
```

### Common Optimizations

1. **Path caching** - Router already implements this
2. **Component pooling** - Max 50 per type by default
3. **Template caching** - Enabled in production
4. **Connection pooling** - For Redis cache

### Benchmarking

```bash
# Run performance specs
crystal spec spec/integration/performance_spec.cr

# Manual benchmarking
crystal build --release playground/benchmark.cr
./benchmark
```

---

## Debugging Tips

### Development Mode

```crystal
Azu.configure do |config|
  config.env = Environment::Development
  config.template_hot_reload = true
end
```

### Logging

```crystal
Log.for("azu.new_feature").info { "Processing request" }
Log.for("azu.new_feature").debug { "Details: #{data}" }
```

### Dev Dashboard

Available at `/dev-dashboard` in development mode:

- Route listing
- Request metrics
- Component status
