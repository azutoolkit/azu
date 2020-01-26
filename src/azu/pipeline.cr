module Azu
  # This class picks the correct pipeline based on the request
  # and executes it.
  class Pipeline
    include Enumerable({Symbol, Array(HTTP::Handler)})
    forward_missing_to @pipelines

    class EmptyPipeline < Exception
    end
    
    property namespace = :web
    getter pipelines = {} of Symbol => Array(HTTP::Handler)
    getter handlers = {} of Symbol => (HTTP::Handler | (HTTP::Server::Context ->))

    def call(context : HTTP::Server::Context)
      raise RouteNotFound.new unless result = ROUTES.find(path(context))
      namespace, endpoint = result.payload
      @handlers[namespace].call(context) if @handlers[namespace]
      endpoint.new(context, result.params).call
    rescue e
      Error(500).new(e)
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
        pipes = self[scope]
        raise EmptyPipeline.new if pipes.empty?
        return @handlers[namespace] = pipes.first if pipes.size == 1

        0.upto(pipes.size - 1) { |i| pipes[i].next = pipes[i + 1] }
        @handlers[namespace] = pipes.first
      end
    end

    private def path(context)
      upgrade_path(context) + context.request.method.downcase + context.request.path.rstrip('/')
    end

    private def upgrade_path(context)
      return "/ws" if context.request.headers.includes_word?("Upgrade", "Websocket")
      "/"
    end
  end
end
