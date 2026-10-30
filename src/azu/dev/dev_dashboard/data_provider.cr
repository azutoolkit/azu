require "../dashboard_snapshot"

module Azu::Components
  # Compatibility facade; browser and terminal share the same calculations.
  class DashboardDataProvider < Azu::Dev::DashboardSnapshot
  end
end
