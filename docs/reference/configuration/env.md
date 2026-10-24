# Azu::Env

`Azu::Env` is the one place an application reads its environment: `.env` files, typed accessors and secrets.
It uses only the standard library, so `require "azu/env"` works on its own, and nothing happens when it is
required. Files are read only when you call `load` or `load_all`.

```crystal
require "azu/env"

# Before `require "azu"`: Azu::CONFIG reads PORT, HOST and CRYSTAL_ENV when azu is required.
Azu::Env.load_all

require "azu"

Azu::Env.required("DATABASE_URL", "CSRF_SECRET")
port = Azu::Env.int("PORT", 4000)
csrf_secret = Azu::Env.secret("CSRF_SECRET")
```

## Loading files

| Call | What it does |
| --- | --- |
| `Azu::Env.load(path = ".env", override = false, unsafe = false)` | Reads one file; returns the names it set. A missing file is not an error. |
| `Azu::Env.load_all(dir = ".", override = false, unsafe = false)` | Reads `.env`, `.env.<CRYSTAL_ENV>` and `.env.local` from `dir`. |
| `Azu::Env.parse(text)` | Parses text into a `Hash(String, String)` and touches nothing else. |

Precedence, highest first:

1. the process environment (a variable the process already has, even an empty one, is never replaced)
2. `.env.local` (your machine; keep it out of git)
3. `.env.<CRYSTAL_ENV>` (`.env.production`, `.env.test`, ...; `development` when `CRYSTAL_ENV` is unset)
4. `.env`

So a container that injects real values is unaffected by a `.env` baked into the image. `override: true`
makes the file win over the process environment; use it in tooling, not in an application.
`CRYSTAL_ENV` itself may be set in `.env` or `.env.local`; the process value wins unless it is blank (blank counts as
unset for `CRYSTAL_ENV`, as `Env.environment` treats it).

### File format

```
# comment
KEY=value
export OTHER=value            # an export prefix is accepted
SPACED = value # a comment after whitespace ends a bare value
QUOTED="line one\nline two"   # \n \t \r \" \\ are unescaped, other backslashes stay as written
LITERAL='no $expansion \n'    # single quotes are literal
MULTI="first
second"                       # quoted values may span lines
```

`$VAR`, `${VAR}`, backticks and `$(...)` are ordinary characters: there is no interpolation and nothing is
executed. A malformed line raises `Azu::Env::ParseError` naming the file and line (never the text), and **one bad
line fails the whole file**: it sets nothing. A file larger than 1 MB is refused. Paths in values (such as
`sqlite3://./db/app.db`) are relative to the process's working directory, not to the file.

### Trust

An application loads its own `.env`, so the file is trusted for its own settings, but a copied or cloned file must not
be able to change how processes start. `load` and `load_all` therefore **skip, with a warning naming the variable
(never the value)**, these names (case-insensitive): `LD_*`, `DYLD_*`, `PATH`, `SHELL`, `IFS`, `BASH_ENV`, `ENV`,
`SHARDS_*`, `CRYSTAL_PATH`, `CRYSTAL_OPTS`, `CRYSTAL_LIBRARY_PATH`, `GIT_*`, `DOCKER_HOST` and `HOME`. Pass
`unsafe: true` to load them anyway; set them in the real environment otherwise. The `azu` CLI applies the same list
to the `.env` of whatever project you run it in, and never lets a file override the real environment.

## Reading values

A blank value counts as unset.

| Call | Returns |
| --- | --- |
| `fetch?(name)` | `String?` |
| `fetch(name)` / `fetch(name, default)` | `String`; without a default raises `MissingError` |
| `bool(name)` / `bool(name, default)` | `true/false/1/0/yes/no/on/off`, any case |
| `int(name)` / `int(name, default)` | `Int32` |
| `url(name)` / `url(name, default)` | `URI` (needs a scheme) |
| `environment` / `production?` | `CRYSTAL_ENV` lowercased, `development` when unset |

Errors name the variable and never its value: `PORT is not an integer`, `DATABASE_URL is not a URL`.

## Boot checks and secrets

`Azu::Env.required(*names)` raises one `Azu::Env::MissingError` listing every missing name
(`DATABASE_URL, CSRF_SECRET are not set`); `error.names` has them as an array.

`Azu::Env.secret(name)` is the guard the generated applications use: the variable when set; a random value
outside production (the same value for the life of the process, so two readers of one name agree); an
`Azu::Env::MissingError` (`CSRF_SECRET is not set`) in production.

**The random fallback is per process.** Two processes, or one process after a restart, get different values, so signed
cookies, CSRF tokens and sessions stop validating. `secret` logs one warning per name when it falls back; set the
variable in `.env` in development.

**Only `production` is strict by default.** Staging gets random secrets unless you list it: set
`AZU_STRICT_ENVS=production,staging` or `Azu::Env.strict_environments = ["production", "staging"]` (`nil` restores
the default), and `secret` raises there too.

```crystal
require "azu"

Azu::Handler::CSRF.configure do |csrf|
  csrf.secret_key = Azu::Env.secret("CSRF_SECRET")
end
```

## Logging

`Azu::Env.redact(name, value)` returns `[FILTERED]` for names that look like secrets (`SECRET`, `PASSWORD`,
`TOKEN`, `PRIVATE`, `CREDENTIAL`, `*KEY`, `COOKIE`, `AUTH`, `DSN`, `SALT`, `SIGNING`) and hides the password inside a URL;
`Azu::Env.redacted(hash)` does it for a hash. Use them whenever you print variables.

## What Azu reads through it

`Azu::Configuration` reads `PORT`, `HOST`, `CRYSTAL_ENV` and `DATABASE_URL` (the deprecated
`config.database.uri`) with `Env`, so an invalid `PORT` fails with a message naming it. The generated
applications of `azu new` load `.env` at boot and read `CSRF_SECRET` / `SESSION_SECRET` with `Env.secret`.
