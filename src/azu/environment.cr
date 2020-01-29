module Azu
  class Environment
    KEY = "CRYSTAL_ENV"
    getter env : String = ENV.fetch(KEY, "dev")

    def in?(env_list : Array(Symbol))
      env_list.any? { |env2| self == env2 }
    end

    def in?(*env_list : Object)
      in?(env_list.to_a)
    end

    def to_s(io)
      io << @env
    end

    def ==(other : Symbol)
      @env == other.to_s.downcase
    end

    macro method_missing(call)
      env_name = {{call.name.id.stringify}}
      (env_name.ends_with?('?') && env == env_name[0..-2])
    end
  end
end
