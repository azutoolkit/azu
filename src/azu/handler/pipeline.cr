module Azu
  # Pipelines provide a convenient mechanism for filtering HTTP requests entering your application.
  #
  # For Example:
  #
  # ExampleApp.pipelines do
  #   middleware[:web] = [
  #   Azu::Rescuer.new,
  #     Azu::Logger.new

  #   build :api do
  #     # plug api filters
  #   end
  # end
  class Pipeline
    include HTTP::Handler

    CONTENT_TYPE = "Content-Type"
    RADIX        = Radix::Tree(HTTP::Handler).new
    PIPELINES    = {} of Symbol => Set(HTTP::Handler)
    RESCUER      = Handler::Rescuer.new

    def self.[]=(key : Symbol, middlewares : Array(HTTP::Handler))
      PIPELINES[key] = Set(HTTP::Handler).new unless PIPELINES.has_key? key
      middlewares.each { |m| PIPELINES[key] << m }
    end

    def self.[](key : Symbol)
      PIPELINES[key]
    end

    def call(context : HTTP::Server::Context)
      resource = path context
      result = RADIX.find resource
      raise Response::NotFound.new(context.request.path) unless result.found?
      context.request.path_params = result.params
      result.payload.call(context)
    rescue ex : Response::Error
      ContentNegotiator.content context, ex 
    end

    # :nodoc:
    protected def prepare
      Router::ROUTES.each do |route|
        pipes = PIPELINES[route.namespace]
        handler = build_pipeline(pipes, last_pipe: route.endpoint)
        RADIX.add route.resource, handler
      end

      Router::SOCKETS.each do |socket|
        RADIX.add socket.resource, socket.channel
      end
    end

    private def path(context)
      upgraded = upgrade?(context)
      String.build do |str|
        str << "/"
        str << "ws" if upgraded
        str << context.request.method.downcase unless upgraded
        str << context.request.path.rstrip('/')
      end
    end

    private def build_pipeline(pipes : Set(HTTP::Handler), last_pipe : HTTP::Handler)
      return last_pipe if pipes.empty?

      dup = pipes.map &.dup
      0.upto(dup.size - 2) { |i| dup[i].next = dup[i + 1] }
      dup.last.next = last_pipe if last_pipe
      dup.first
    end

    private def upgrade?(context)
      return unless upgrade = context.request.headers["Upgrade"]?
      return unless upgrade.compare("websocket", case_insensitive: true) == 0
      context.request.headers.includes_word?("Connection", "Upgrade")
    end
  end
end
