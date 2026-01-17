# Doc Skill

Generate and serve Crystal API documentation.

## Usage
```
/doc [options]
```

## Options
- `--serve` - Generate and serve documentation locally
- `--output <path>` - Custom output directory (default: `docs/api`)
- `--open` - Open documentation in browser after generation
- `--json` - Generate JSON documentation (for tooling)

## Examples
```
/doc                    # Generate documentation
/doc --serve            # Generate and serve on localhost
/doc --output api-docs  # Custom output directory
/doc --open             # Generate and open in browser
```

## Instructions

When this skill is invoked:

1. **Default (no options):** Generate HTML documentation
   ```bash
   crystal docs --output=docs/api
   ```

2. **With `--serve`:** Generate and serve locally
   ```bash
   crystal docs --output=docs/api
   cd docs/api && python3 -m http.server 8080
   ```
   Then inform user: "Documentation available at http://localhost:8080"

3. **With `--output`:** Use custom directory
   ```bash
   crystal docs --output=<path>
   ```

4. **With `--open`:** Generate and open browser
   ```bash
   crystal docs --output=docs/api
   open docs/api/index.html  # macOS
   ```

5. **With `--json`:** Generate JSON for tooling
   ```bash
   crystal docs --format=json --output=docs/api.json
   ```

## Documentation Structure

Generated docs include:
- `index.html` - Main entry point
- Module/class documentation
- Method signatures with types
- Source code links

## Best Practices

When generating docs:
1. Ensure all public methods have doc comments
2. Include usage examples in module docs
3. Document exceptions that can be raised
4. Link related types using backticks

## Example Doc Comment
```crystal
# Finds a user by their unique identifier.
#
# Returns `nil` if no user is found with the given ID.
#
# ```
# user = User.find(123)
# user.try(&.name) # => "John"
# ```
#
# Raises `DatabaseError` if the connection fails.
def self.find(id : Int64) : User?
end
```
