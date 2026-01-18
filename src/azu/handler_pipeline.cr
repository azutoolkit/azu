require "http/server/handler"

module Azu
  # Fluent builder for composing HTTP handler middleware pipelines
  #
  # The HandlerPipeline provides a clean, chainable API for building
  # middleware stacks. Handlers are executed in the order they are added.
  #
  # Example:
  # ```
  # pipeline = Azu::HandlerPipeline.new
  #   .use(Azu::Handler::Rescuer.new)
  #   .use(Azu::Handler::CORS.new(origins: ["https://example.com"]))
  #   .use(Azu::Handler::CSRF.new)
  #   .use { |ctx| puts "Request: #{ctx.request.path}" }
  #   .build
  #
  # # Use with HTTP::Server
  # server = HTTP::Server.new(pipeline) { |ctx| ... }
  # ```
  class HandlerPipeline
    @handlers = [] of HTTP::Handler

    # Add a handler to the pipeline
    #
    # Handlers are executed in the order they are added.
    # Each handler should call `call_next(context)` to continue the chain.
    def use(handler : HTTP::Handler) : self
      @handlers << handler
      self
    end

    # Add a block-based handler to the pipeline
    #
    # The block receives the HTTP context and should process the request.
    # The next handler in the chain is called automatically after the block.
    #
    # Example:
    # ```
    # pipeline.use { |ctx| ctx.response.headers["X-Custom"] = "value" }
    # ```
    def use(&block : HTTP::Server::Context -> Nil) : self
      @handlers << BlockHandler.new(block)
      self
    end

    # Add a handler conditionally
    #
    # The handler is only added if the condition is true.
    #
    # Example:
    # ```
    # pipeline.use_if(ENV["ENABLE_CORS"]? == "true", cors_handler)
    # ```
    def use_if(condition : Bool, handler : HTTP::Handler) : self
      @handlers << handler if condition
      self
    end

    # Build the handler chain
    #
    # Returns the first handler in the chain with all handlers linked together.
    # Raises if the pipeline is empty.
    def build : HTTP::Handler
      raise EmptyPipelineError.new("Cannot build an empty handler pipeline") if @handlers.empty?

      # Link handlers in chain
      @handlers.each_with_index do |handler, index|
        if index < @handlers.size - 1
          handler.next = @handlers[index + 1]
        end
      end

      @handlers.first
    end

    # Build the handler chain, returning nil if empty
    def build? : HTTP::Handler?
      return nil if @handlers.empty?
      build
    end

    # Returns the number of handlers in the pipeline
    def size : Int32
      @handlers.size
    end

    # Returns true if no handlers have been added
    def empty? : Bool
      @handlers.empty?
    end

    # Clear all handlers from the pipeline
    def clear : self
      @handlers.clear
      self
    end

    # Error raised when trying to build an empty pipeline
    class EmptyPipelineError < Exception
    end

    # Internal handler that wraps a block
    private class BlockHandler
      include HTTP::Handler

      def initialize(@block : HTTP::Server::Context -> Nil)
      end

      def call(context : HTTP::Server::Context)
        @block.call(context)
        call_next(context)
      end
    end
  end
end
