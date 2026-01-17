# Build Skill

Build Crystal projects and targets.

## Usage

```
/build [options] [target]
```

## Options

- `--release` - Build with optimizations (production)
- `--static` - Build static binary
- `--debug` - Include debug symbols
- `--verbose` - Show detailed compilation output
- `--clean` - Clean before building

## Targets

- `example` - Build the playground example app
- `lib` - Build library only (check for errors)
- Default: Build main target from shard.yml

## Examples

```
/build                      # Build default target
/build example              # Build example app
/build --release            # Production build
/build --release --static   # Static production binary
/build --clean              # Clean and rebuild
```

## Instructions

When this skill is invoked:

1. **Default (no options):** Build using shards

   ```bash
   shards build
   ```

2. **With `example` target:** Build playground app

   ```bash
   crystal build playground/example_app.cr -o bin/example_app
   ```

3. **With `--release`:** Optimized production build

   ```bash
   shards build --release
   # Or for specific target:
   crystal build playground/example_app.cr -o bin/example_app --release
   ```

4. **With `--static`:** Static binary (requires static Crystal)

   ```bash
   crystal build playground/example_app.cr -o bin/example_app --release --static
   ```

5. **With `--debug`:** Include debug info

   ```bash
   crystal build playground/example_app.cr -o bin/example_app --debug
   ```

6. **With `--clean`:** Clean build artifacts first

   ```bash
   rm -rf lib/.shards bin/
   shards install
   shards build
   ```

7. **With `lib` target:** Verify library compiles
   ```bash
   crystal build src/azu.cr --no-codegen
   ```

## Build Output

- Binary location: `bin/` directory
- Report build time
- Report binary size for release builds
- List any warnings during compilation

## Troubleshooting

Common build issues:

- **Missing shards:** Run `shards install`
- **Version conflicts:** Check `shard.lock` vs `shard.yml`
- **LLVM issues:** Verify Crystal installation
- **Static build fails:** Check for dynamic library dependencies
