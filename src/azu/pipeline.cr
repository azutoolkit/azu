module Azu
  class Pipeline
    include HTTP::Handler

    CONTENT_TYPE = "Content-Type"
    RADIX        = Radix::Tree(HTTP::Handler).new

    getter pipelines = {} of Symbol => Set(HTTP::Handler)

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
      @pipelines[namespace] = Set(HTTP::Handler).new unless @pipelines.has_key? namespace
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

    def build_pipeline(pipes : Set(HTTP::Handler), last_pipe : HTTP::Handler)
      if pipes.empty?
        last_pipe
      else
        dup = pipes.map &.dup
        0.upto(dup.size - 2) { |i| dup[i].next = dup[i + 1] }
        dup.last.next = last_pipe if last_pipe
        dup.first
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
