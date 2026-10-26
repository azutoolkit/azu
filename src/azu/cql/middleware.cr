module Azu
  module CQL
    # A plain `HTTP::Handler` for the chain of an app (`app.server([...])`, `app.default_handlers`):
    # it opens the request's `RequestContext` (so every SQL statement and transaction is tagged with
    # the request in `QueryStore`) and, with `transaction: true`, runs the rest of the chain in a CQL
    # transaction on one connection.
    #
    #   app.server(app.default_handlers + [Azu::CQL::Middleware.new(AppDB, transaction: true)] of HTTP::Handler)
    #
    # The transaction commits when the response status is below `rollback_from` (400 by default) and
    # rolls back on an exception (which keeps propagating, so put the handler *after* `Rescuer`, which
    # renders it) or a status of `rollback_from` and above. Failed model validations that escape as
    # CQL exceptions become `Response::ValidationError` (422). Transactions are per fiber, so requests
    # served concurrently never share one. Without `transaction` CQL checks out a pooled connection per
    # statement, as usual.
    class Middleware
      include HTTP::Handler

      getter? transaction : Bool
      getter rollback_from : Int32

      # `schema` is resolved on first use when given as a block (`Middleware.new(transaction: true) { AppDB }`),
      # since initializers run before `db/schema.cr`.
      def initialize(@schema : ::CQL::Schema, @transaction : Bool = false, @rollback_from : Int32 = 400)
        @provider = nil
      end

      def initialize(@transaction : Bool = false, @rollback_from : Int32 = 400, &@provider : -> ::CQL::Schema)
        @schema = nil
      end

      # Raised inside the transaction to roll it back for a status, and caught right outside it: CQL logs
      # a warning for every `DB::Rollback`, which would flood the log with one line per 4xx.
      private class StatusRollback < Exception
        include Instrumentor::IntentionalRollback # a rolled back transaction, not an error, in the dashboard
      end

      def call(context : HTTP::Server::Context) : Nil
        RequestContext.scope(context) do |_|
          @transaction ? within_transaction(context) : call_next(context)
        rescue error : ::CQL::RecordInvalid
          raise CQL.unprocessable(error)
        rescue error : ::CQL::ValidationError
          raise CQL.unprocessable(error)
        rescue error : ::CQL::ActiveRecord::Validations::ValidationError
          raise CQL.unprocessable(error)
        end
      end

      private def within_transaction(context : HTTP::Server::Context) : Nil
        handled = false
        begin
          schema.transaction do |_tx|
            call_next(context)
            handled = true
            raise StatusRollback.new if context.response.status_code >= @rollback_from
          end
        rescue StatusRollback
        rescue error
          discard_success(context) if handled # the commit failed: the buffered success must not precede the error page
          raise error
        end
      end

      private def discard_success(context : HTTP::Server::Context) : Nil
        return if context.response.wrote_headers?
        context.response.reset
        HeadOutput.wrap(context) # reset puts back the original output, which would send a HEAD's error page
      end

      private def schema : ::CQL::Schema
        @schema ||= (@provider || raise ArgumentError.new("Azu::CQL::Middleware needs a schema")).call
      end
    end
  end
end
