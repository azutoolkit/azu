module Azu
  module Spark
    # Reports component lifecycle timings (`mount`, `unmount`, `refresh`, `event_handler:<name>`)
    # to `Azu::Instrumentation`; `azu/dev` turns them into metrics for the dev dashboard.
    module Instrumentation
      def self.measure(entry : Entry, event : String, &)
        Azu::Instrumentation.component(entry.id, entry.component.class.name, event, entry.mounted_at) { yield }
      end
    end
  end
end
