# Run Skill

Run Crystal applications and examples.

## Usage
```
/run [options] [target]
```

## Options
- `--port <port>` - Specify server port (default: 4000)
- `--host <host>` - Specify host binding (default: 0.0.0.0)
- `--env <env>` - Set environment (development, test, production)
- `--watch` - Enable file watching for auto-reload

## Targets
- `example` - Run the playground example app (default)
- `<file.cr>` - Run specific Crystal file

## Examples
```
/run                        # Run example app
/run --port 3000            # Run on port 3000
/run --env production       # Run in production mode
/run playground/custom.cr   # Run custom file
```

## Instructions

When this skill is invoked:

1. **Default (no options):** Run example application
   ```bash
   crystal run playground/example_app.cr
   ```

2. **With `--port`:** Set custom port
   ```bash
   PORT=3000 crystal run playground/example_app.cr
   ```

3. **With `--host`:** Set custom host
   ```bash
   HOST=127.0.0.1 crystal run playground/example_app.cr
   ```

4. **With `--env`:** Set environment
   ```bash
   AZU_ENV=production crystal run playground/example_app.cr
   ```

5. **With `--watch`:** Enable file watching (requires sentry or similar)
   ```bash
   # If sentry is available:
   sentry -r playground/example_app.cr
   # Otherwise, manual restart required
   crystal run playground/example_app.cr
   ```

6. **With custom file:** Run specified file
   ```bash
   crystal run <file.cr>
   ```

## Server Output

After starting, report:
- Server URL (http://host:port)
- Environment mode
- Available endpoints (from router)
- Hot-reload status (if enabled)

## Development Tools

When running in development mode:
- Dev dashboard available at `/dev-dashboard`
- Template hot-reload enabled
- Detailed error pages shown
- Performance monitoring active

## Stopping

The server runs in foreground. To stop:
- Press Ctrl+C
- Or use `/kill` skill to terminate background processes
