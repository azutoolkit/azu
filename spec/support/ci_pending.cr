# In CI a spec that needs a server or a feature must not silently turn pending: a missing PostgreSQL service
# would leave the engine path untested without anyone noticing. Outside CI the example is pending. In CI it fails,
# unless the workflow lists what may be skipped in AZU_CI_ALLOW_PENDING (comma separated: `postgres`, `engine`).
module CIPending
  def self.ci? : Bool
    !ENV["CI"]?.nil?
  end

  def self.allowed?(what : String) : Bool
    (ENV["AZU_CI_ALLOW_PENDING"]? || "").split(',').map(&.strip).includes?(what)
  end

  # Call inside an example.
  macro skip!(what, reason)
    if CIPending.ci? && !CIPending.allowed?({{ what }})
      fail({{ reason }} + " (CI must not skip this; AZU_CI_ALLOW_PENDING=" + {{ what }} + " allows it)")
    else
      pending!({{ reason }})
    end
  end
end
