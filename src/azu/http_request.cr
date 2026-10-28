require "mime"

# :nodoc:
class HTTP::Request
  @path_params : Hash(String, String)? = nil
  @accept : Array(MIME::MediaType)? = nil

  # True once `Azu::Handler::CORS`, earlier in the chain, matched the request's `Origin` header against the
  # origins it lists (not a `*` wildcard, which vouches for nobody): `Azu::Handler::CSRF` then skips its own
  # same-origin check for the request. A field, not a header, so a client cannot set it.
  property? cors_allowed : Bool = false

  def content_type : MIME::MediaType
    if content = headers["Content-Type"]?
      MIME::MediaType.parse(content)
    else
      MIME::MediaType.parse("text/plain")
    end
  end

  def path_params : Hash(String, String)
    @path_params ||= {} of String => String
  end

  # The path params as written, nil when none were: unlike `path_params`, reading them allocates nothing.
  def path_params? : Hash(String, String)?
    @path_params
  end

  # Nil forgets them: the router writes nil for a route without parameters, which a mounted app's router does after
  # the mount's own route wrote its `mount_path`.
  def path_params=(params : Hash(String, String)?)
    @path_params = params
  end

  # The media ranges of the `Accept` header, best quality first; nil without a header or when no range parses.
  # A client's header is never a reason to fail: a range that does not parse is skipped and a `q` that is not a
  # number (or is outside 0..1) counts as 1.0, the rules `Negotiation` applies. The error pages rely on this: they
  # are rendered from inside `Rescuer`, where a raise would turn any error into an unhandled 500.
  def accept : Array(MIME::MediaType) | Nil
    @accept ||= (
      if header = headers["Accept"]?
        ranges = header.split(',').compact_map { |range| accept_range(range) }
        return nil if ranges.empty?

        # The highest quality first; a stable sort keeps the header's order among equals
        ranges.sort_by! { |range| -accept_quality(range) }
      end
    )
  end

  private def accept_range(entry : String) : MIME::MediaType?
    trimmed = entry.strip
    return if trimmed.empty?

    media = MIME::MediaType.parse(trimmed)
    media if media.sub_type.presence
  rescue MIME::Error
    nil
  end

  private def accept_quality(media : MIME::MediaType) : Float64
    quality = media["q"]?.try(&.to_f?)
    quality && quality.finite? ? quality.clamp(0.0, 1.0) : 1.0
  end
end
