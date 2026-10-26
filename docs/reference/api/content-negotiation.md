---
description: "One response type renders itself as HTML, JSON, XML or plain text, and the request's `Accept` header picks the format."
---

# Content negotiation

`Azu::Response::Negotiable` finds the formats a type defines, `Azu::Negotiation` chooses
among them, and a client that accepts none of them gets a `406`. Both come with `require "azu"`. A response that does
not include `Negotiable` is not negotiated.

Include the module and define any of `render_html`, `render_json`, `render_xml` and `render_text`,
each returning a `String`:

```crystal
require "azu"

struct UserPage
  include Azu::Response::Negotiable

  def initialize(@name : String)
  end

  def render_html : String
    "<h1>#{HTML.escape(@name)}</h1>"
  end

  def render_json : String
    {name: @name}.to_json
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserPage)

  get "/users/:name"

  def call : UserPage
    UserPage.new("Ada")
  end
end
```

`UserPage.formats` is `[Html, Json]`. The response is sent with the matching `Content-Type`
(`text/html; charset=utf-8`, `application/json`, `application/xml`, `text/plain; charset=utf-8`) and
`Vary: Accept`.

## API

### Calling the negotiator yourself

```crystal
require "azu"

def best(request : HTTP::Request) : Azu::Negotiation::Format?
  Azu::Negotiation.negotiate([Azu::Negotiation::Format::Json, Azu::Negotiation::Format::Html], request)
end
```

`Negotiation.negotiate!` raises `Azu::Response::NotAcceptable` instead of returning `nil`, and
`Negotiation.ranges(header)` returns the parsed `MediaRange`s.

## Options

### Overriding the header with `?format=`

`/users/ada?format=json` answers in JSON whatever `Accept` says. The values are `html`, `json`, `xml`,
`text` and `txt`; one of those the response does not define is a `406`. Any other value
(`?format=csv`) is ignored, so an endpoint can have a `format` field of its own. If it takes the values
above as well, rename the parameter, or turn it off with `nil`:

```crystal
require "azu"

Azu::CONFIG.format_parameter = "as" # /users/ada?as=json
```

The name `format` is reserved for this by default (the
[`format_parameter` option](../configuration/options.md#request-contracts)).

## Behavior

### How a format is chosen

The `Accept` header is parsed into media ranges (with `MIME::MediaType`) and each format is rated
against them:

1. A format scores the `q` of the **most specific** range that matches it (`text/html` beats `text/*`
   beats `*/*`), so `text/*;q=0.1, text/html;q=0.8` rates HTML at `0.8`.
2. The highest `q` wins. `q=0` refuses a format.
3. On a tie, the more specific range wins, then the range written first in the header, then the
   format's place in `formats`.

A request without `Accept`, with an empty one, with `*/*`, or with a header in which no entry is a valid
media range, gets the first format. That is HTML, then JSON, XML and text, unless the type says
otherwise:

```crystal
require "azu"

struct ApiUser
  include Azu::Response::Negotiable

  prefer :json, :html

  def render_html : String
    "<p>Ada</p>"
  end

  def render_json : String
    %({"name":"Ada"})
  end
end
```

`ApiUser.formats` is `[Json, Html]`, so `curl` (`Accept: */*`) gets JSON and a browser still gets HTML.

### 406 Not Acceptable

When no format matches, the answer is `406` with `Vary: Accept` and a body that lists what can be
rendered, as an RFC 7807 problem document (`application/problem+json` when the client names it in `Accept`, `application/json` otherwise), in the style of the 422 of a failed contract:

```json
{
  "type": "about:blank",
  "title": "Not Acceptable",
  "status": 406,
  "detail": "None of the media types in the Accept header can be rendered. Supported: application/json, text/html.",
  "supported": ["application/json", "text/html"]
}
```

It is sent as `application/problem+json` only when the Accept header names it, otherwise as `application/json` (always so with
`error_format = Azu::ErrorFormat::Legacy`). It is JSON
whatever the client accepts, since it just said it accepts nothing the response renders.

An endpoint declared with a `Negotiable` response type (`Endpoint(Request, UserPage)`) refuses the
request **before `call` runs**: a `POST` that cannot be answered creates nothing. For a union of
negotiable types (`Endpoint(Request, UserPage | OtherPage)`) the check uses the formats all members
render (members must be public types: macros cannot name private ones).

{% hint style="warning" %}
A union with a member that is not negotiable, and a hand written endpoint, is checked only when the
response is written, after `call`: for an unsafe method use a single response type, or negotiate in `call`
with `Azu::Negotiation.negotiate!` before doing anything.
{% endhint %}

### OpenAPI

The document lists every media type of a negotiated response under the `200` response. The JSON one
carries the response schema when the type is a `JSON::Serializable`; the others are described as strings.

## Limits

- There is no path extension (`/users/ada.json`): routes are matched on the path as written, and a query parameter
  needs no routing support.
- The formats are HTML, JSON, XML and plain text; there is no hook for another media type.

## See also

- [Response](response.md)
- [Return different formats](../../how-to/endpoints/return-different-formats.md)
- [Error types](../errors/error-types.md)
