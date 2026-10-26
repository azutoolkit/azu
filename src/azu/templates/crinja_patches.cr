# Every reopening of Crinja that Azu makes lives in this file. They target Crinja 0.9.0, which shard.yml pins
# (`~> 0.9.0`): check each one against Crinja's source before moving the pin.

class Fiber
  # :nodoc:
  # The Crinja contexts this fiber is rendering in, innermost last, each with its environment (see `Crinja#context`).
  property crinja_scopes : Array({Crinja, Crinja::Context})?
end

class Crinja
  # Crinja keeps the context of the render in progress on the environment, which every request shares: two renders
  # that overlap (a helper that yields the fiber, threads under preview_mt) read each other's variables, and one that
  # ends out of order leaves its context behind for every later render. Each fiber keeps its own instead, per
  # environment; outside a render a fiber sees the environment's global context.
  def context : Context
    if scopes = Fiber.current.crinja_scopes
      (scopes.size - 1).downto(0) do |index|
        env, current = scopes.unsafe_fetch(index)
        return current if env.same?(self)
      end
    end
    global_context
  end

  # Makes `ctx` this fiber's context in this environment while the block runs.
  def with_scope(ctx : Context, &)
    scopes = Fiber.current.crinja_scopes ||= [] of {Crinja, Context}
    scopes << {self, ctx}
    begin
      yield ctx
    ensure
      scopes.pop
    end
  end

  # As in Crinja, with autoescape set on this fiber's context rather than on the environment's.
  def evaluate(expression, bindings = nil) : String
    parsed = Parser::ExpressionParser.new(Parser::ExpressionLexer.new(config, expression)).parse
    context.autoescape = config.autoescape?
    stringify(evaluate(parsed, bindings))
  end
end
