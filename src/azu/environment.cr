module Azu
  enum Environment
    Development
    Staging
    Production
    
    def in?(environments : Array(Symbol))
      environments.any? { |name| self == name }
    end

    def in?(*environments : Environment)
      in?(environments.to_a)
    end

  end
end
