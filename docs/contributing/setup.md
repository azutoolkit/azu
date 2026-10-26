---
description: How to get a working checkout of Azu, run its specs and checks, and try a change.
---

# Development setup

## Prerequisites

- **Crystal 1.22.1 or newer.** CI runs 1.22.1 and the latest release. Install it from
  [crystal-lang.org/install](https://crystal-lang.org/install/) and check it with `crystal --version`.
- **Git**, and a fork of [azutoolkit/azu](https://github.com/azutoolkit/azu) if you want to open a pull request.
- **SQLite development headers** (`libsqlite3-dev` on Debian and Ubuntu): the specs link against SQLite.
- **Redis** is optional; the cache specs that need it are skipped when no server answers.

## Get the code

```bash
git clone https://github.com/your-username/azu.git
cd azu
git remote add upstream https://github.com/azutoolkit/azu.git
git checkout -b feature/your-feature-name
shards install
```

Use `fix/...` for bug fixes and `docs/...` for documentation changes.

## Build and test

```bash
crystal spec                      # all specs
crystal spec spec/azu/             # one directory
crystal spec spec/azu/router_spec.cr   # one file
crystal run playground/example_app.cr  # the example application
```

The specs live under `spec/`, mirroring `src/`. A spec that needs a running server starts the app on a free
port in the same process:

```crystal
require "spec"
require "http/client"
require "azu"

struct PingResponse
  include Azu::Response

  def render
    "pong"
  end
end

struct PingEndpoint
  include Azu::Endpoint(Azu::Request, PingResponse)

  get "/ping"

  def call : PingResponse
    content_type "text/plain"
    PingResponse.new
  end
end

describe PingEndpoint do
  it "answers pong" do
    server = Azu::App.default.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    begin
      response = HTTP::Client.get("http://#{address}/ping")
      response.status_code.should eq 200
      response.body.should eq "pong"
    ensure
      server.close
    end
  end
end
```

## Format and lint

```bash
crystal tool format                # format the code
crystal tool format --check --exclude lib --exclude playground/lib   # what CI runs
ameba                              # static analysis (see .ameba.yml)
```

{% hint style="info" %}
[Ameba](https://github.com/crystal-ameba/ameba) is not a dependency of this shard: install it separately.
{% endhint %}

## Documentation

The Markdown under `docs/` and `README.md` is type-checked. Every file listed in `docs/.checked` has all of
its `crystal` blocks compiled against your checkout:

```bash
crystal run scripts/check_docs.cr -- docs/faq.md
```

A block that is only a fragment opts out with `<!-- skip -->` on the line before its fence. Blocks that show
something that is not meant to compile (shell output, historical APIs) use another language tag such as
`text`. CI fails when a Markdown file has a `crystal` block and is not listed in `docs/.checked`.

`crystal docs` generates the API documentation from the doc comments in `src/`.

## Before you open a pull request

1. `crystal spec` passes.
2. `crystal tool format --check --exclude lib --exclude playground/lib` is clean.
3. `ameba` reports nothing new.
4. Behaviour changes have a spec, and documentation that mentions the changed API is updated.

## Troubleshooting

- **`shards install` complains about the Crystal version:** use `shards install --ignore-crystal-version` if you
  run a compiler newer than the one `shard.yml` was written for.
- **The linker cannot find `sqlite3`:** install the SQLite development package for your system.
- **Dependencies out of date:** `shards update`.

## Next steps

- [Code Standards](standards.md) - Coding standards and guidelines
- [Roadmap](roadmap.md) - Development roadmap and priorities
