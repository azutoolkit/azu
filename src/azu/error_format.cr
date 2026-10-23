module Azu
  # How request validation failures are answered.
  enum ErrorFormat
    # RFC 7807 `application/problem+json` with the failing fields under `errors`.
    Problem
    # The body of Azu before 0.6, kept for one minor release.
    Legacy
  end
end
