module Azu
  class Pipeline
    include HTTP::Handler
    include Enumerable({Symbol, Array(HTTP::Handler)})

    forward_missing_to @pipelines

    CONTENT_TYPE = "Content-Type"

    class EmptyPipeline < Exception
    end

    class RouteNotFound < Exception
    end

    property namespace = :web
    getter pipelines = {} of Symbol => Array(HTTP::Handler)
    getter handlers = {} of Symbol => HTTP::Handler

    def call(context : HTTP::Server::Context)
      raise RouteNotFound.new unless context.request.route = Router::ROUTES.find(path(context))
      namespace, endpoint = context.request.route.not_nil!.payload.not_nil!
      @handlers[namespace].call(context) if @handlers[namespace]
    end

    def each
      @pipelines.each { |pipeline| yield pipeline }
    end

    def build(namespace : Symbol, &block)
      @namespace = namespace
      self[namespace] = [] of HTTP::Handler unless has_key? namespace
      with self yield
    end

    def plug(pipe : HTTP::Handler)
      self[namespace] << pipe
    end

    def prepare
      keys.each do |scope|
        @handlers[namespace] = build_pipeline(self[scope], last_pipe: Render.new)
      end
    end

    def build_pipeline(pipes, last_pipe : HTTP::Handler)
      if pipes.empty?
        last_pipe
      else
        0.upto(pipes.size - 2) { |i| pipes[i].next = pipes[i + 1] }
        pipes.last.next = last_pipe if last_pipe
        pipes.first
      end
    end

    protected def path(context)
      upgrade_path(context) + context.request.method.downcase + context.request.path.rstrip('/')
    end

    protected def upgrade_path(context)
      return "/ws" if context.request.headers.includes_word?("Upgrade", "Websocket")
      "/"
    end
  end
end
