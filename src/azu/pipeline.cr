module Azu
  class Pipeline
    include HTTP::Handler
    include Enumerable({Symbol, Array(HTTP::Handler)})

    CONTENT_TYPE = "Content-Type"

    property namespace = :web
    getter pipelines = {} of Symbol => Array(HTTP::Handler)
    getter handlers = {} of Symbol => HTTP::Handler

    forward_missing_to @pipelines

    delegate :find, to: Router::ROUTES

    def call(context : HTTP::Server::Context)
      result = find(path(context))
      unless result.found?
        return NotFound.new(detail: "Path #{context.request.path} not defined", source: context.request.path)
          .render(context)
      end
      namespace, _ = result.payload
      context.request.route = result
      handlers[namespace].call(context) if handlers[namespace]
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
      keys.each do |pipeline|
        handlers[pipeline] = build_pipeline(self[pipeline], last_pipe: Render.new)
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
