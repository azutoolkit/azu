# Lint Skill

Run Crystal code linting and formatting checks.

## Usage
```
/lint [options]
```

## Options
- `--fix` - Auto-fix formatting issues
- `--check` - Check only (CI mode)
- `--ameba` - Run Ameba static analysis only
- `--format` - Run crystal format only

## Instructions

When this skill is invoked:

1. **Default behavior (no options):** Run both formatting check and Ameba analysis
   ```bash
   crystal tool format --check src/ spec/
   ameba src/ spec/
   ```

2. **With `--fix`:** Auto-fix formatting issues
   ```bash
   crystal tool format src/ spec/
   ```

3. **With `--check`:** CI-compatible check mode
   ```bash
   crystal tool format --check src/ spec/ && ameba src/ spec/
   ```

4. **With `--ameba`:** Run only Ameba static analysis
   ```bash
   ameba src/ spec/
   ```

5. **With `--format`:** Run only formatting
   ```bash
   crystal tool format src/ spec/
   ```

## Output Handling

- If formatting issues are found, list the affected files
- If Ameba finds issues, summarize by severity (error, warning, convention)
- For `--fix`, report how many files were modified
- Exit with non-zero status if any issues found (for CI integration)

## Configuration

Ameba is configured via `.ameba.yml` in the project root:
- Max cyclomatic complexity: 10
- Excluded files: performance_monitor, components, demo_reporting
