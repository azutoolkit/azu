require "digest/sha256"
require "http/server"

module Azu
  module Spark
    # The browser half of Spark. The script ships inside the shard (embedded at compile time),
    # is served by the application itself and is never loaded from a CDN, so the version in the
    # browser always matches the protocol version of the server.
    module Client
      SOURCE = {{ read_file("#{__DIR__}/client/azu_spark.js") }}

      # Content hash, used as cache buster: the URL changes exactly when the script does.
      VERSION = Digest::SHA256.hexdigest(SOURCE)[0, 12]

      # Serves the script. With the matching `?v=` it is cacheable forever; without it the
      # browser has to revalidate through the ETag.
      class Asset
        include HTTP::Handler

        def call(context : HTTP::Server::Context)
          response = context.response
          etag = %("#{VERSION}")
          response.content_type = "application/javascript; charset=utf-8"
          response.headers["ETag"] = etag
          response.headers["X-Content-Type-Options"] = "nosniff"
          response.headers["Cache-Control"] = context.request.query_params["v"]? == VERSION ? "public, max-age=31536000, immutable" : "no-cache"
          if context.request.headers["If-None-Match"]? == etag
            response.status = :not_modified
          elsif context.request.method != "HEAD"
            response.print SOURCE
          end
        end
      end
    end
  end
end
