require "uri"

module Azu
  module Database
    # Turns configuration + environment into one connection URL.
    #
    # Precedence: `config.url`, `DATABASE_URL`, `AZU_DB_*` / `PG*` variables,
    # `postgres://localhost/<app>_<env>`. Pool settings are appended as query
    # parameters (understood by crystal-db) unless the URL already sets them.
    module URLResolver
      extend self

      # `environ` is injectable so specs can pass a fake environment.
      def resolve(config : DatabaseConfiguration, env : Environment, app_name : String, environ : Hash(String, String) = ENV.to_h) : String
        url = config.url.presence || environ["DATABASE_URL"]?.presence || from_parts(environ) || convention(app_name, env)
        apply_pool(url, config)
      end

      # Same URL with the password replaced, safe to log.
      def redact(url : String) : String
        url.sub(%r{(://[^:/@]*:)[^@]*@}, "\\1***@")
      end

      # "my-app" / "MyApp" / "my_app.cr" -> "my_app"
      def app_slug(program : String) : String
        File.basename(program, ".cr").gsub(/[^A-Za-z0-9]+/, "_").underscore.strip('_').presence || "app"
      end

      private def from_parts(environ : Hash(String, String)) : String?
        name = environ["AZU_DB_NAME"]? || environ["PGDATABASE"]?
        return unless name
        host = environ["AZU_DB_HOST"]? || environ["PGHOST"]? || "localhost"
        port = environ["AZU_DB_PORT"]? || environ["PGPORT"]?
        user = environ["AZU_DB_USER"]? || environ["PGUSER"]?
        password = environ["AZU_DB_PASSWORD"]? || environ["PGPASSWORD"]?
        String.build do |io|
          io << "postgres://"
          if user
            io << URI.encode_path_segment(user)
            io << ':' << URI.encode_path_segment(password) if password
            io << '@'
          end
          io << host
          io << ':' << port if port
          io << '/' << name
        end
      end

      private def convention(app_name : String, env : Environment) : String
        "postgres://localhost/#{app_name}_#{env.to_s.downcase}"
      end

      private def apply_pool(url : String, config : DatabaseConfiguration) : String
        size = config.pool_size
        timeout = config.checkout_timeout
        return url unless size || timeout

        uri = URI.parse(url)
        params = uri.query_params
        if size && !params.has_key?("max_pool_size")
          params["max_pool_size"] = size.to_s
          params["max_idle_pool_size"] = size.to_s unless params.has_key?("max_idle_pool_size")
        end
        params["checkout_timeout"] = timeout.to_s if timeout && !params.has_key?("checkout_timeout")
        uri.query = params.to_s
        uri.to_s
      end
    end
  end
end
