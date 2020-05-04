module Azu
  class Pipeline
    include HTTP::Handler

    CONTENT_TYPE = "Content-Type"
    RADIX        = Radix::Tree(HTTP::Handler).new

    getter pipelines = {} of Symbol => Array(HTTP::Handler)

    def call(context : HTTP::Server::Context)
      resource = path context
      result = RADIX.find resource
      raise NotFound.new(context.request.path) unless result.found?
      context.request.path_params = result.params
      result.payload.call(context)
    rescue ex : Azu::Error
      view = ErrorView.new(context, ex)
      context.response.reset
      context.response.status_code = ex.status
      context.response.print ContentNegotiator.content(context, view)
      context
    end

    def build(namespace : Symbol, &block)
      @namespace = namespace
      @pipelines[namespace] = [] of HTTP::Handler unless @pipelines.has_key? namespace
      with self yield
    end

    def plug(pipe : HTTP::Handler)
      @pipelines[@namespace] << pipe
    end

    def prepare
      Router::ROUTES.each do |route|
        pipes = @pipelines[route.namespace]
        handler = build_pipeline(pipes, last_pipe: route.endpoint)
        RADIX.add route.resource, handler
      end
    end

    def build_pipeline(pipes : Array(HTTP::Handler), last_pipe : HTTP::Handler)
      if pipes.empty?
        last_pipe
      else
        0.upto(pipes.size - 2) { |i| pipes[i].next = pipes[i + 1] }
        pipes.last.next = last_pipe if last_pipe
        pipes.first
      end
    end

    protected def path(context)
      String.build do |str|
        str << "/"
        str << "ws" if context.request.headers.includes_word?("Upgrade", "Websocket")
        str << context.request.method.downcase
        str << context.request.path.rstrip('/')
      end
    end
  end
end
