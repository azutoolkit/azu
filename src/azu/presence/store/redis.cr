require "redis"
require "../store"

module Azu
  module Presence
    class Store
      # Redis store shared by every node. A topic is the hash `<prefix>t:<topic>` (`ref` => meta JSON) and the
      # leases are the hash `<prefix>nodes` (`node` => expiry in unix milliseconds). Expiry is decided by
      # readers from the leases, not by Redis key TTLs, so it follows `Azu::Clock`; the topic hashes carry
      # a long Redis TTL only as a last resort for topics nobody reads or renews any more.
      #
      # With `server_time: true` (the default) leases are written and judged against the Redis `TIME`, so the
      # nodes need no synchronized clocks. `server_time: false` uses `Azu::Clock` instead, which lets specs drive
      # expiry with a fake clock.
      #
      # One mutex-guarded connection is opened on first use. A dead connection is discarded and the command
      # retried once on a fresh one.
      class Redis < Store
        DEFAULT_PREFIX = "azu:presence:"
        RETENTION      = 1.day
        TIMEOUT        = 5.seconds

        FIELD_SEPARATOR = '\u001f'

        def initialize(@url : String = ENV.fetch("PRESENCE_REDIS_URL", ENV.fetch("PUBSUB_REDIS_URL", "redis://localhost:6379/0")),
                       @prefix : String = DEFAULT_PREFIX, @server_time : Bool = true)
          @mutex = Mutex.new
          @connection = nil.as(::Redis?)
        end

        def put(topic : String, meta : Meta) : Nil
          key = topic_key(topic)
          run do |redis|
            redis.hset(key, field(meta), meta.to_json)
            redis.expire(key, RETENTION.total_seconds.to_i)
          end
        end

        def delete(topic : String, meta : Meta) : Nil
          evict(topic, [meta])
        end

        def stored(topic : String) : Array(Meta)
          run(&.hgetall(topic_key(topic))).values.compact_map { |json| parse(json) }
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
          run(&.command(["HDEL", topic_key(topic)] + metas.map { |meta| field(meta) }))
        end

        def now : Time
          return super unless @server_time
          seconds, micros = run(&.command(["TIME"])).as(Array).map(&.as(String).to_i64)
          Time.unix(seconds) + micros.microseconds
        end

        # Scans only the fields of *key* (`<key>\u001f<ref>`), so tracking does not read the whole topic.
        def present?(topic : String, key : String, now : Time, grace : Time::Span) : Bool
          alive = leases.select { |_, expires_at| expires_at > now }
          fields = run { |redis| matching_fields(redis, topic_key(topic), "#{escape_glob(key)}#{FIELD_SEPARATOR}*") }
          fields.any? { |field| alive.has_key?(node_of(field)) }
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

        private def matching_fields(redis : ::Redis, hash : String, pattern : String) : Array(String)
          cursor = "0"
          fields = [] of String
          loop do
            reply = redis.command(["HSCAN", hash, cursor, "MATCH", pattern, "COUNT", "500"]).as(Array)
            cursor = reply[0].as(String)
            reply[1].as(Array).each_slice(2) { |pair| fields << pair[0].as(String) }
            break if cursor == "0"
          end
          fields
        end

        private def field(meta : Meta) : String
          "#{meta.key}#{FIELD_SEPARATOR}#{meta.ref}"
        end

        # The node of a field: its ref is `<node>.<counter>`.
        private def node_of(field : String) : String
          field.partition(FIELD_SEPARATOR)[2].rpartition('.')[0]
        end

        private def escape_glob(text : String) : String
          text.gsub(/[\\*?\[\]]/) { |char| "\\#{char}" }
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

        private def nodes_key : String
          "#{@prefix}nodes"
        end
      end
    end
  end
end
