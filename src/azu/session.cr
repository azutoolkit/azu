require "base64"
require "json"
require "http/cookie"
require "openssl/hmac"
require "crypto/subtle"

module Azu
  # Signed-cookie session and one-request flash messages.
  #
  # Inside an `Azu::Endpoint` they are available as `session` and `flash`:
  #
  # ```
  # session[:user_id] = user.id.to_s
  # redirect_to "/dashboard", notice: "Welcome back!"
  # ```
  #
  # The session lives in the `_azu_session` cookie as `base64(json).hmac`, signed with
  # `Azu::CONFIG.secret_key_base` (set the `SECRET_KEY_BASE` environment variable in
  # production, otherwise a random key is generated on every boot and sessions do not
  # survive a restart). The signed payload is tamper-proof but **not encrypted**, so keep
  # secrets out of it. Cookies are limited to about 4 KB.
  class Session
    COOKIE_NAME = "_azu_session"
    MAX_BYTES   = 4000

    # Flash messages: values set now are readable on the *next* request only.
    class Flash
      COOKIE_NAME = "_flash"

      # Messages written by the previous request, readable now.
      getter current : Hash(String, String)
      # Messages that will be readable on the next request.
      getter upcoming : Hash(String, String) = Hash(String, String).new

      def initialize(@current : Hash(String, String) = Hash(String, String).new)
      end

      def []=(key : String | Symbol, value : String) : String
        upcoming[key.to_s] = value
      end

      def []?(key : String | Symbol) : String?
        current[key.to_s]?
      end

      def [](key : String | Symbol) : String
        self[key]? || raise KeyError.new("Missing flash key: #{key}")
      end

      def notice : String?
        self[:notice]?
      end

      def alert : String?
        self[:alert]?
      end

      # Keeps the messages of this request for one more request.
      def keep : Nil
        current.each { |key, value| upcoming[key] ||= value }
      end

      def empty? : Bool
        current.empty? && upcoming.empty?
      end

      # :nodoc:
      def self.read(cookies : HTTP::Cookies) : Flash
        data = Hash(String, String).new
        if cookie = cookies[COOKIE_NAME]?
          begin
            JSON.parse(Base64.decode_string(cookie.value)).as_h.each do |key, value|
              data[key] = value.as_s
            end
          rescue JSON::ParseException | Base64::Error | TypeCastError
            data.clear
          end
        end
        new(data)
      end
    end

    getter data : Hash(String, String)
    getter flash : Flash
    getter? changed : Bool = false

    def initialize(@data : Hash(String, String) = Hash(String, String).new, @flash : Flash = Flash.new)
    end

    # Reads and verifies the session of *cookies*. A missing, malformed or forged
    # cookie yields an empty session.
    def self.load(cookies : HTTP::Cookies, secret : String = CONFIG.secret_key_base) : Session
      new(verify(cookies[COOKIE_NAME]?.try(&.value), secret), Flash.read(cookies))
    end

    def [](key : String | Symbol) : String
      data[key.to_s]? || raise KeyError.new("Missing session key: #{key}")
    end

    def []?(key : String | Symbol) : String?
      data[key.to_s]?
    end

    def []=(key : String | Symbol, value : String | Int | Bool) : String
      @changed = true
      data[key.to_s] = value.to_s
    end

    def delete(key : String | Symbol) : String?
      @changed = true
      data.delete(key.to_s)
    end

    def has_key?(key : String | Symbol) : Bool
      data.has_key?(key.to_s)
    end

    # Empties the session, e.g. on logout.
    def clear : Nil
      @changed = true
      data.clear
    end

    # Writes the session and flash cookies when they changed.
    def commit(request : HTTP::Request, response : HTTP::Server::Response, secret : String = CONFIG.secret_key_base) : Nil
      secure = request.headers["X-Forwarded-Proto"]? == "https" || request.headers["Host"]?.try(&.ends_with?(":443")) || false
      if changed?
        if data.empty?
          response.cookies << expired(COOKIE_NAME)
        else
          response.cookies << cookie(COOKIE_NAME, sign(data, secret), secure)
        end
      end

      if !flash.upcoming.empty?
        response.cookies << cookie(Flash::COOKIE_NAME, Base64.strict_encode(flash.upcoming.to_json), secure)
      elsif !flash.current.empty?
        response.cookies << expired(Flash::COOKIE_NAME)
      end
    end

    private def cookie(name : String, value : String, secure : Bool) : HTTP::Cookie
      if value.bytesize > MAX_BYTES
        raise ArgumentError.new("Cookie #{name} is #{value.bytesize} bytes; the limit is #{MAX_BYTES}. Store less in the session.")
      end
      HTTP::Cookie.new(name, value, path: "/", http_only: true, secure: secure, samesite: HTTP::Cookie::SameSite::Lax)
    end

    private def expired(name : String) : HTTP::Cookie
      HTTP::Cookie.new(name, "", path: "/", expires: Time.utc(1970, 1, 1), max_age: 0.seconds)
    end

    private def sign(payload : Hash(String, String), secret : String) : String
      encoded = Base64.urlsafe_encode(payload.to_json, padding: false)
      "#{encoded}.#{OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)}"
    end

    private def self.verify(value : String?, secret : String) : Hash(String, String)
      data = Hash(String, String).new
      return data unless value

      encoded, _, signature = value.rpartition('.')
      return data if encoded.empty?
      expected = OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)
      return data unless Crypto::Subtle.constant_time_compare(expected, signature)

      JSON.parse(Base64.decode_string(encoded)).as_h.each { |key, item| data[key] = item.as_s }
      data
    rescue JSON::ParseException | Base64::Error | TypeCastError
      Hash(String, String).new
    end
  end
end
