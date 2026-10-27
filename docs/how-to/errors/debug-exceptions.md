---
description: Read Azu's development exception page, open frames in your editor, find every error in the dev dashboard, and add likely causes and signals of your own.
---

# Debug exceptions

Before you start: an app with `Azu::Handler::Rescuer` in its handler chain (the default stack has it), running in
development (`CRYSTAL_ENV` unset or `development`).

## Read the exception page

When a request raises, a browser in development gets Azu's exception page. On a wide screen it has two columns; on a
narrower one they are stacked.

The left column says what failed and where:

- the status, the request line and the endpoint that served it, and how long the request ran before it failed;
- the exception class and its message (credentials in it are redacted);
- **Raised in**: the first frame of *your* code, not of Azu, a shard or the standard library;
- **Likely cause**: what an exception of that class usually means and where to look, ranked by severity;
- the source around the line that raised.

The right column has four tabs:

| Tab | Shows |
|---|---|
| Stack | The backtrace grouped into your application, Azu, shards and Crystal (only your frames are open), and the exceptions it was caused by |
| Signals | What was recorded around the request: its SQL queries, the endpoint's recent history, how often this error happened, the process memory |
| Request | Method, path, endpoint, request id, client, query parameters, headers and cookies, with credentials replaced by `[FILTERED]` |
| Environment | Azu and Crystal versions, the process, and the (redacted) environment variables |

**Copy as Markdown** puts the class, message, request, likely causes and your frames on the clipboard, ready for an
issue or a chat. The theme button switches light and dark; the choice is shared with the dev dashboard.

JSON clients get the same triage: in development the problem body has an `exception` member with `class`, `message`,
`location`, `hints`, `frames`, `causes`, `request`, `signals` and `dashboard_url`. A plain-text client gets
`Raised in:` and `Likely cause:` lines at the top of the body.

{% hint style="info" %}
Outside development none of this reaches a client. HTML clients get the `error.html` page (a status, a plain sentence
about it and a reference id), JSON clients the problem members `type`, `title`, `status`, `detail`, `errors`, `error_id`
and `instance`.
{% endhint %}

## Open frames in your editor

Set `AZU_EDITOR` and every frame becomes a link that opens the file at its line:

```bash
AZU_EDITOR=vscode crystal run src/app.cr
```

Names it knows: `vscode`, `cursor`, `windsurf`, `zed`, `idea`, `rubymine`, `sublime`, `textmate`, `emacs`, `nova`. Any
other editor takes a template with `%{file}`, `%{line}` and `%{column}`:

```bash
AZU_EDITOR="myeditor://open?path=%{file}&line=%{line}"
```

## Find every error in the dev dashboard

With `require "azu/dev"` and `Azu::Handler::DevDashboard` mounted (see [Use the dev dashboard](../performance/use-dev-dashboard.md)),
every server error is kept: unexpected exceptions and 5xx responses, not 4xx refusals. The dashboard's **Errors** tab
lists them grouped by class and the line of your code that raised them, with a count, the occurrences of the last hour
and when each was last seen.

**Open** shows the error's exception page as it was when it happened, with the previous and next occurrences one click
away. The exception page of a live request links to it (**Open in dashboard**), and so does the Logs entry of the
request.

The dashboard keeps the latest 100 errors; clearing its metrics forgets them. Tools can read them as JSON:
`GET /dev-dashboard/errors.json` lists the groups, `GET /dev-dashboard/errors/<id>.json` returns one report.

{% hint style="info" %}
The **Signals** tab fills in as you turn on more instrumentation: `PERFORMANCE_MONITORING=true` adds the endpoint's
request count, error rate and latency; `azu/cql` with database instrumentation adds the request's queries, the one that
failed and N+1 patterns.
{% endhint %}

## Add likely causes of your own

Register a hint for an exception class of your app or a shard. The block gets the exception and the report and returns
a `Hint`, or `nil` when it has nothing to say:

```crystal
class PaymentDeclined < Exception
  getter code : String

  def initialize(@code : String)
    super("The payment was declined (#{code})")
  end
end

Azu::ExceptionPage.hint(PaymentDeclined) do |error, _report|
  Azu::ExceptionPage::Hint.new("The card was declined", "The gateway said `#{error.code}`: ask for another card.", :info)
end
```

`Hint.new(title, detail, tone)` takes a tone of `:bad`, `:warn`, `:info` or `:good`; text between backticks is shown
as code.

## Add signals of your own

A panel provider adds a card to the Signals tab, and hints of its own. It runs for every failure, so keep it cheap.
This one shows which release is running, and warns when the error comes from an uncommitted build:

```crystal
Azu::ExceptionPage.on_panels do |_report|
  commit = ENV["GIT_SHA"]? || "unknown"
  hints = [] of Azu::ExceptionPage::Hint
  hints << Azu::ExceptionPage::Hint.new("This build is not from a commit", "Set `GIT_SHA` when you build.", :info) if commit == "unknown"

  [Azu::ExceptionPage::Panel.new("Release", "config",
    stats: [Azu::ExceptionPage::Stat.new("Commit", commit)], hints: hints)]
end
```

A provider that raises is skipped; the page still renders.

## Send errors to a tracker

`Azu::Instrumentation.on_exception` receives the same report for every server error, in any environment, so it can
forward errors to an external service:

```crystal
Azu::Instrumentation.on_exception do |report|
  Log.for("errors").error { "#{report.exception_class}: #{report.message} (#{report.fingerprint}, #{report.request.id})" }
end
```

Replace the log line with your tracker's client call.

The report holds redacted request data only.
