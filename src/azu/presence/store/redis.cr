require "redis"
require "../store"

module Azu
  module Presence
    class Store
      # Redis store shared by every node. A topic is the hash `<prefix>t:<topic>` (`ref` => meta JSON), each key of
      # a topic has an index hash `<prefix>k:<topic>\u001f<key>` (`ref` => node, so "is this key present" reads one
      # small hash, not the topic), and the leases are the hash `<prefix>nodes` (`node` => expiry in unix
      # milliseconds). Expiry is decided by readers from the leases, not by Redis key TTLs, so it follows
      # `Azu::Clock`; the hashes carry a long Redis TTL only as a last resort for topics nobody renews any more.
      #
      # With `server_time: true` (the default) leases are written and judged against the Redis `TIME`, so the
      # nodes need no synchronized clocks. `server_time: false` uses `Azu::Clock` instead, which lets specs drive
      # expiry with a fake clock.
      #
      # One mutex-guarded connection is opened on first use. A dead connection is discarded and the command
      # retried once on a fresh one. The topic hash and the key index of a meta are written in one `MULTI`, so
      # they cannot drift apart on a retry. `refresh` writes the index entries of the metas a node owns again,
      # which repairs an index that lost one; the caller must pass only metas that are still owned.
      class Redis < Store
        DEFAULT_PREFIX = "azu:presence:"
        RETENTION      = 1.day
        TIMEOUT        = 5.seconds

        def initialize(@url : String = ENV.fetch("PRESENCE_REDIS_URL", ENV.fetch("PUBSUB_REDIS_URL", "redis://localhost:6379/0")),
                       @prefix : String = DEFAULT_PREFIX, @server_time : Bool = true)
          @mutex = Mutex.new
          @connection = nil.as(::Redis?)
        end

        def put(topic : String, meta : Meta) : Nil
          run do |redis|
            redis.multi do |transaction|
              transaction.command(["HSET", topic_key(topic), meta.ref, meta.to_json])
              transaction.command(["HSET", index_key(topic, meta.key), meta.ref, meta.node])
              expire(transaction, topic, meta.key)
            end
          end
        end

        def delete(topic : String, meta : Meta) : Nil
          evict(topic, [meta])
        end

        def stored(topic : String) : Array(Meta)
          run(&.hgetall(topic_key(topic))).values.compact_map { |json| parse(json) }
        end

        def refs(topic : String) : Array(String)
          run(&.command(["HKEYS", topic_key(topic)])).as(Array).map(&.as(String))
        end

        def refresh(topic : String, metas : Array(Meta)) : Nil
          run do |redis|
            redis.pipelined do |pipeline|
              metas.each do |meta|
                pipeline.command(["HSET", index_key(topic, meta.key), meta.ref, meta.node])
                expire(pipeline, topic, meta.key)
              end
            end
          end
        end

        def renew(node : String, expires_at : Time) : Nil
          run(&.hset(nodes_key, node, expires_at.to_unix_ms))
        end

        def leases : Hash(String, Time)
          run(&.hgetall(nodes_key)).transform_values { |millis| Time.unix_ms(millis.to_i64) }
        end

        def forget(nodes : Array(String)) : Nil
          return if nodes.empty?
          run(&.command(["HDEL", nodes_key] + nodes))
        end

        def evict(topic : String, metas : Array(Meta)) : Nil
          return if metas.empty?
          run do |redis|
            redis.multi do |transaction|
              transaction.command(["HDEL", topic_key(topic)] + metas.map(&.ref))
              metas.each { |meta| transaction.command(["HDEL", index_key(topic, meta.key), meta.ref]) }
            end
          end
        end

        def now : Time
          return super unless @server_time
          seconds, micros = run(&.command(["TIME"])).as(Array).map(&.as(String).to_i64)
          Time.unix(seconds) + micros.microseconds
        end

        # Reads the index hash of *key* only, so the cost does not grow with the topic.
        def present?(topic : String, key : String, now : Time, grace : Time::Span) : Bool
          nodes = run(&.hgetall(index_key(topic, key))).values
          return false if nodes.empty?
          alive = leases
          nodes.any? { |node| (lease = alive[node]?) && lease > now }
        end

        def shutdown : Nil
          @mutex.synchronize do
            @connection.try(&.close)
            @connection = nil
          end
        end

        private def run(& : ::Redis -> T) : T forall T
          @mutex.synchronize do
            yield (@connection ||= connect)
          rescue ::Redis::Error | IO::Error
            discard
            yield (@connection = connect)
          end
        end

        private def expire(commands, topic : String, key : String) : Nil
          seconds = RETENTION.total_seconds.to_i.to_s
          commands.command(["EXPIRE", topic_key(topic), seconds])
          commands.command(["EXPIRE", index_key(topic, key), seconds])
        end

        private def discard : Nil
          connection, @connection = @connection, nil
          begin
            connection.try(&.close)
          rescue ::Redis::Error | IO::Error
          end
        end

        private def connect : ::Redis
          ::Redis.new(url: @url, reconnect: false, connect_timeout: TIMEOUT, command_timeout: TIMEOUT)
        end

        private def parse(json : String) : Meta?
          Meta.from_json(json)
        rescue JSON::ParseException | JSON::SerializableError
          Log.for("Azu::Presence").warn { "Ignoring a malformed presence entry in Redis" }
        end

        private def topic_key(topic : String) : String
          "#{@prefix}t:#{topic}"
        end

        private def index_key(topic : String, key : String) : String
          "#{@prefix}k:#{topic}\u001f#{key}"
        end

        private def nodes_key : String
          "#{@prefix}nodes"
        end
      end
    end
  end
end
