require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Routes" tab: the ordered middleware pipeline, then the route tree grouped
      # by first path segment. Rows carry `data-filter`/`data-method` so the quick
      # filter, the verb toggles and the command palette can all find them.
      module RoutesSection
        private abstract def provider : DashboardDataProvider

        private def render_routes : Nil
          render_pipeline
          render_route_tree
        end

        private def render_pipeline : Nil
          handlers = provider.pipeline
          card "Middleware pipeline", "pipeline", meta: "#{handlers.size} handlers" do
            if handlers.empty?
              empty_state "Pipeline not registered", "Start the app with MyApp.start [handlers] (App#start) so their order can be shown here.", "pipeline"
            else
              ol class: "azd-pipeline" do
                li "Request", class: "azd-node is-edge"
                handlers.each { |name| render_pipeline_node(name) }
                li "Router", class: "azd-node is-edge"
              end
            end
          end
        end

        private def render_pipeline_node(name : String) : Nil
          namespace, _, short = name.rpartition("::")
          li class: "azd-node#{" is-self" if short == "DevDashboard"}" do
            span "#{namespace}::", class: "azd-ns" unless namespace.empty?
            strong short
          end
        end

        private def render_route_tree : Nil
          routes = provider.routes
          card "Registered routes", "routes", meta: "#{routes.size} routes" do
            if routes.empty?
              empty_state "No routes registered", "Routes declared with get/post/... appear here.", "routes"
            else
              render_verb_toggles(routes)
              div class: "azd-tree" do
                routes.group_by { |route| route_group(route["path"]) }.each do |group, members|
                  render_route_group(group, members)
                end
              end
            end
          end
        end

        private def render_verb_toggles(routes : Array(Hash(String, String))) : Nil
          div class: "azd-seg", role: "group", aria_label: "Filter routes by HTTP method" do
            routes.map { |route| route["method"] }.tally.each do |verb, count|
              button type: "button", class: "azd-seg-btn", data_action: "method", data_method: verb, aria_pressed: "false" do
                verb_chip verb
                span count.to_s, class: "azd-count"
              end
            end
          end
        end

        private def render_route_group(group : String, members : Array(Hash(String, String))) : Nil
          details class: "azd-group", open: nil, data_group: nil do
            summary do
              icon "chevron"
              span group, class: "azd-group-name"
              span members.size.to_s, class: "azd-count"
            end
            members.each { |route| render_route(route) }
          end
        end

        private def render_route(route : Hash(String, String)) : Nil
          verb, path = route["method"], route["path"]
          div class: "azd-route", data_filter: "#{verb} #{path} #{route["handler"]}", data_method: verb, data_route: path do
            verb_chip verb
            code class: "azd-path" do
              render_path(path)
            end
            span route["handler"], class: "azd-handler"
            copy_button "endpoint #{verb} #{path}", "#{verb} #{path}"
          end
        end

        # Path segments as text, with `:param` and `*glob` segments highlighted.
        private def render_path(path : String) : Nil
          path.split('/').each_with_index do |segment, i|
            text "/" if i > 0
            if segment.starts_with?(':') || segment.starts_with?('*')
              span segment, class: "azd-param"
            else
              text segment
            end
          end
        end

        private def route_group(path : String) : String
          segment = path.split('/')[1]?
          segment.nil? || segment.empty? ? "/" : "/#{segment}"
        end
      end
    end
  end
end
