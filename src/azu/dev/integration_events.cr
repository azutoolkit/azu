require "json"

module Azu::Dev
  # Optional, metadata-only development adapters. No session values, addresses,
  # email bodies or credentials are accepted by the event API.
  module IntegrationEvents
    record Event, at : String, name : String, outcome : String
    @@mutex = Mutex.new
    @@sessions = [] of Event
    @@mailers = [] of Event
    @@previews = {} of String => String
    @@backend : String? = nil
    @@active : Int64? = nil

    def self.enabled? : Bool
      Azu.current_config.env.development?
    end

    def self.sessions(backend : String, active : Int64? = nil) : Nil
      return unless enabled? && {"cookie", "redis", "memory"}.includes?(backend)
      @@mutex.synchronize do
        @@backend = backend
        @@active = backend == "cookie" ? nil : active.try(&.clamp(0_i64, Int64::MAX))
      end
    end

    def self.session(event : String, outcome : String) : Nil
      return unless enabled? && {"sign-in", "sign-out", "sign-up", "created", "expired"}.includes?(event)
      return unless {"accepted", "rejected", "throttled"}.includes?(outcome)
      @@mutex.synchronize { append(@@sessions, event, outcome) }
    end

    # Register static example text only; previews never execute deliveries.
    def self.mailer(name : String, preview : String = "Preview not supplied") : Nil
      return unless enabled?
      @@mutex.synchronize do
        return if @@previews.size >= 100 && !@@previews.has_key?(name)
        @@previews[name[0, 128]] = preview[0, 2048]
      end
    end

    def self.delivery(name : String, outcome : String) : Nil
      return unless enabled? && {"delivered", "failed"}.includes?(outcome)
      @@mutex.synchronize { append(@@mailers, name[0, 128], outcome) }
    end

    private def self.append(list : Array(Event), name : String, outcome : String) : Nil
      list.shift if list.size >= 100
      list << Event.new(Time.utc.to_rfc3339, name, outcome)
    end

    def self.snapshot
      @@mutex.synchronize do
        {
          sessions: {backend: @@backend, active: @@active, recent: @@sessions.reverse.map { |e| {at: e.at, event: e.name, outcome: e.outcome} }},
          mailers:  {registered: @@previews.map { |name, preview| {name: name, preview: preview} }, recent: @@mailers.reverse.map { |e| {at: e.at, name: e.name, outcome: e.outcome} }},
        }
      end
    end

    def self.reset : Nil
      @@mutex.synchronize do
        @@sessions.clear
        @@mailers.clear
        @@previews.clear
        @@backend = nil
        @@active = nil
      end
    end
  end
end
