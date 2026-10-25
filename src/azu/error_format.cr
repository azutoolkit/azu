module Azu
  # How request validation failures are answered.
  enum ErrorFormat
    # RFC 7807 problem body (`application/problem+json` when the client names it in `Accept`) with the failing fields under `errors`.
    Problem
    # The body of Azu before 0.6, kept for one minor release.
    Legacy
  end
end
