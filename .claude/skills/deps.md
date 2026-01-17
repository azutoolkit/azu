# Deps Skill

Manage Crystal shard dependencies.

## Usage
```
/deps [action] [options]
```

## Actions
- `install` - Install dependencies (default)
- `update` - Update dependencies
- `outdated` - Check for outdated shards
- `add <shard>` - Add a new dependency
- `remove <shard>` - Remove a dependency
- `list` - List installed dependencies

## Options
- `--production` - Install without development dependencies
- `--skip-postinstall` - Skip post-install scripts

## Examples
```
/deps                           # Install dependencies
/deps install                   # Same as above
/deps update                    # Update all shards
/deps outdated                  # Check for updates
/deps add redis                 # Add redis shard
/deps add kemal --version 1.0   # Add with version
/deps remove redis              # Remove shard
/deps list                      # Show dependency tree
```

## Instructions

When this skill is invoked:

1. **Default / `install`:** Install all dependencies
   ```bash
   shards install
   ```

2. **`update`:** Update to latest compatible versions
   ```bash
   shards update
   ```

3. **`outdated`:** Check for available updates
   ```bash
   shards outdated
   ```

4. **`add <shard>`:** Add new dependency
   - Read current `shard.yml`
   - Add the shard to dependencies section
   - Optionally specify version constraint
   - Run `shards install`

5. **`remove <shard>`:** Remove dependency
   - Read current `shard.yml`
   - Remove the shard from dependencies
   - Run `shards install`
   - Clean up unused files in `lib/`

6. **`list`:** Display dependency tree
   ```bash
   shards list
   ```

7. **With `--production`:** Skip dev dependencies
   ```bash
   shards install --production
   ```

## Dependency Management Best Practices

### Version Constraints
- `~> 1.0` - Compatible with 1.x (recommended)
- `>= 1.0, < 2.0` - Explicit range
- Exact version only when necessary

### Adding Dependencies
When adding a shard, I will:
1. Check if it's already in dependencies
2. Look up the latest version
3. Add with appropriate version constraint
4. Update `shard.yml` with formatted YAML
5. Run install to verify

### Lock File
- `shard.lock` pins exact versions
- Commit lock file for reproducible builds
- `shards update` refreshes lock file

## Current Dependencies

From `shard.yml`:
- **radix** - Routing
- **exception_page** - Error pages
- **schema** - Validation
- **crinja** - Templates
- **redis ~> 2.9.0** - Caching
