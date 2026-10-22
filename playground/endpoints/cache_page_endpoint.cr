require "../../src/azu"
require "../requests/empty_request"
require "../requests/user_form_request"
require "../responses/page"

module ExampleApp
  COUNTER_KEY = "playground:counter"

  struct CachePageEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    get "/cache"

    def call : Page
      content_type "text/html"
      count = Azu.cache.get(COUNTER_KEY).try(&.to_i?) || 0
      stats = Azu.cache.stats.map { |key, value| {label: key.tr("_", " ").capitalize, value: value.to_s} }
      Page.new("cache.html", context, "cache", count: count, stats: stats)
    end
  end

  struct CounterFormEndpoint
    include Azu::Endpoint(CounterForm, Page)

    post "/cache/counter"

    def call : Page
      case counter_form.action
      when "increment" then Azu.cache.increment(COUNTER_KEY, ttl: 1.hour)
      when "decrement" then Azu.cache.decrement(COUNTER_KEY, ttl: 1.hour)
      else                  Azu.cache.delete(COUNTER_KEY)
      end
      status 303
      header "Location", "/cache"
      Page.empty
    end
  end

  struct ClearCacheEndpoint
    include Azu::Endpoint(EmptyRequest, Page)

    post "/cache/empty"

    def call : Page
      Azu.cache.clear
      Flash.set(context, notice: "The cache is empty again.")
      status 303
      header "Location", "/cache"
      Page.empty
    end
  end
end
