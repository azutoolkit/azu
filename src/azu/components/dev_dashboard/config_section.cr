module Azu
  module Components
    module Dashboard
      # "Config" tab: the operational switches of the running app (server, template
      # hot reload, cache, performance monitoring, assets, i18n).
      #
      # Deliberately an allow-list of non-sensitive flags and numbers: no
      # environment dump, no TLS key/cert paths, no Redis URL or other connection
      # strings, no filesystem paths.
      module ConfigSection
        private def render_config : Nil
          config = Azu.current_config
          div class: "azd-grid azd-cards" do
            render_server_config(config)
            render_templates_config(config)
            render_cache_config(config.cache_config)
            render_performance_config(config)
            render_assets_config(config)
          end
        end

        private def render_server_config(config : Configuration) : Nil
          card "Server", "config" do
            facts do
              fact "Environment", config.env.to_s
              fact "Listen address", "#{config.host}:#{config.port}"
              fact("TLS") { flag config.tls? }
              fact("Port reuse") { flag config.port_reuse? }
            end
          end
        end

        private def render_templates_config(config : Configuration) : Nil
          card "Templates", "logs" do
            facts do
              fact("Hot reload (HMR)") { flag config.template_hot_reload? }
            end
          end
        end

        private def render_cache_config(cache : Cache::Configuration) : Nil
          card "Cache", "cache" do
            facts do
              fact("Enabled") { flag cache.enabled? }
              fact "Store", cache.store
              fact "Max size", Format.number(cache.max_size)
              fact "Default TTL", "#{cache.default_ttl}s"
              fact "Key prefix", cache.key_prefix
            end
          end
        end

        private def render_performance_config(config : Configuration) : Nil
          card "Performance", "tracing" do
            facts do
              fact("Request monitoring") { flag config.performance_enabled? }
              fact("Profiler") { flag config.performance_profiling_enabled? }
              fact("Memory monitoring") { flag config.performance_memory_monitoring? }
            end
          end
        end

        private def render_assets_config(config : Configuration) : Nil
          card "Assets, uploads and i18n", "components" do
            facts do
              fact "Assets prefix", config.assets.prefix
              fact("Fingerprinting") { flag config.assets.fingerprint? }
              fact "Max upload size", Format.megabytes(config.upload.max_file_size)
              fact "Default locale", config.i18n.default_locale
            end
          end
        end

        # On/off state as a badge: enabled is green, disabled neutral.
        private def flag(enabled : Bool) : Nil
          enabled ? badge(Status::Good, "Enabled") : badge(Status::Idle, "Disabled")
        end
      end
    end
  end
end
