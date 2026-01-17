# Spec Skill

Run Crystal test specifications.

## Usage
```
/spec [options] [files/patterns]
```

## Options
- `--tag <tag>` - Run tests with specific tag (e.g., `--tag focus`, `--tag slow`)
- `--integration` - Run integration tests only
- `--unit` - Run unit tests only
- `--verbose` - Show detailed output
- `--fail-fast` - Stop on first failure
- `--coverage` - Generate coverage report

## Examples
```
/spec                           # Run all tests
/spec spec/azu/router_spec.cr   # Run specific file
/spec --tag focus               # Run focused tests
/spec --integration             # Run integration tests
/spec --unit --fail-fast        # Run unit tests, stop on first failure
```

## Instructions

When this skill is invoked:

1. **Default (no arguments):** Run all specs
   ```bash
   crystal spec
   ```

2. **With specific files:** Run those files
   ```bash
   crystal spec spec/azu/router_spec.cr spec/azu/endpoint_spec.cr
   ```

3. **With `--tag`:** Run tagged tests
   ```bash
   crystal spec --tag focus
   ```

4. **With `--integration`:** Run integration test suite
   ```bash
   crystal spec spec/integration/
   ```

5. **With `--unit`:** Run unit tests (exclude integration)
   ```bash
   crystal spec spec/azu/
   ```

6. **With `--verbose`:** Enable verbose output
   ```bash
   crystal spec --verbose
   ```

7. **With `--fail-fast`:** Stop on first failure
   ```bash
   crystal spec --fail-fast
   ```

## Test Categories

- **Unit Tests:** `spec/azu/` - Individual module tests
- **Integration Tests:** `spec/integration/` - Full system tests
  - `middleware_chain_spec.cr` - Handler pipeline
  - `error_handling_spec.cr` - Error flows
  - `websocket_spec.cr` - Real-time features
  - `security_spec.cr` - CSRF, CORS, security
  - `static_files_spec.cr` - File serving
  - `performance_spec.cr` - Benchmarks

## Output Handling

- Display test count, pass/fail summary
- On failure, show:
  - Failed test name and location
  - Expected vs actual values
  - Relevant backtrace
- Suggest fixes when patterns are recognized
