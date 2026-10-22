module Azu
  abstract class Model
    # Raised in `n_plus_one = :raise` mode when an association is read lazily on a
    # record that was loaded together with others.
    class UnpreloadedAssociation < Azu::Database::Error
    end

    @@warned = Set(String).new
    @@warned_mutex = Mutex.new

    @[DB::Field(ignore: true)]
    @_azu_batch_size : Int32 = 0
    @[DB::Field(ignore: true)]
    @_azu_batch_id : UInt64 = 0_u64

    # :nodoc: set by `QueryBuilder#all` for records loaded as part of a batch.
    def _azu_tag_batch(size : Int32, id : UInt64) : Nil
      @_azu_batch_size = size
      @_azu_batch_id = id
    end

    # :nodoc: called by association getters that are about to hit the database lazily.
    def _azu_lazy_association(name : Symbol) : Nil
      return unless @_azu_batch_size > 1
      mode = Azu::CONFIG.database.n_plus_one
      return if mode.off?

      message = "N+1 query: #{self.class}##{name} was loaded lazily for a record from a batch of #{@_azu_batch_size}; add preload(:#{name}) to the query"
      raise UnpreloadedAssociation.new(message) if mode.raise?

      # one warning per batch and association, not one per record
      key = "#{self.class}##{name}##{@_azu_batch_id}"
      first_time = @@warned_mutex.synchronize do
        @@warned.clear if @@warned.size > 1_000
        @@warned.add?(key)
      end
      Azu::CONFIG.log.warn { message } if first_time
    end
  end
end

module CQL::ActiveRecord::Queryable
  class QueryBuilder(T)
    # Tags the loaded records with their batch so lazy association reads can be detected.
    def all : Array(T)
      records = previous_def
      {% if T < ::Azu::Model %}
        if records.size > 1 && !Azu::CONFIG.database.n_plus_one.off?
          batch_id = records.object_id
          size = records.size
          records.each(&._azu_tag_batch(size, batch_id))
        end
      {% end %}
      records
    end
  end
end
