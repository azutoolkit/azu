module Azu
  module CQL
    # CQL model validations as Azu's 422 problem+json.
    #
    # CQL and Azu requests share the `validate attribute, predicate: value, message: "..."` macro and most
    # predicates (`presence`, `required`, `size`, `match`, `in`, `exclude`, `eq`); see
    # docs/reference/api/cql-bridge.md for the differences. Both report `{field : Symbol, message : String}`
    # errors, so one conversion serves a model, a request and CQL's exceptions.
    module Validation
      alias FieldErrors = Hash(String, Array(String))

      def self.field_errors(errors : Enumerable) : FieldErrors
        errors.each_with_object(FieldErrors.new) do |error, fields|
          (fields[error.field.to_s] ||= [] of String) << error.message
        end
      end
    end

    # The 422 for a model's validation errors (nothing to raise when there are none).
    def self.unprocessable(errors : Enumerable) : Response::ValidationError
      Response::ValidationError.new(Validation.field_errors(errors))
    end

    def self.unprocessable(error : ::CQL::RecordInvalid) : Response::ValidationError
      fields = Validation::FieldErrors.new
      (error.validation_errors || [] of NamedTuple(field: Symbol, message: String)).each do |entry|
        (fields[entry[:field].to_s] ||= [] of String) << entry[:message]
      end
      Response::ValidationError.new(fields)
    end

    def self.unprocessable(error : ::CQL::ValidationError) : Response::ValidationError
      Response::ValidationError.new(error.errors)
    end

    # `Validations::ValidationError` (raised by `save`) keeps its errors in an ivar without a reader.
    def self.unprocessable(error : ::CQL::ActiveRecord::Validations::ValidationError) : Response::ValidationError
      unprocessable(error.@errors)
    end
  end
end

module CQL::ActiveRecord::Validations
  # Runs the model's validations; returns self when valid, else raises `Azu::Response::ValidationError`
  # (422, problem+json with the failing fields), which an endpoint can `raise` or the `Rescuer` renders.
  def valid_or_422!(context = nil) : self
    failures = errors(context)
    raise Azu::CQL.unprocessable(failures) unless failures.empty?
    self
  end
end
