module Azu
  # IP spoofing is the creation of Internet Protocol (IP) packets which have a
  # modified source address in order to either hide the identity of the sender,
  # to impersonate another computer system, or both. It is a technique often used
  # by bad actors to invoke DDoS attacks against a target device or the surrounding infrastructure.
  #
  # ### Usage
  #
  # ```
  # Azu::Throttle.new
  # ```
  #
  class IpSpoofing
    include HTTP::Handler
    FORWARDED_FOR = "X-Forwarded-For"
    CLIENT_IP     = "X-Client-IP"
    REAL_IP       = "X-Real-IP"

    def call(context : HTTP::Server::Context)
      headers = context.request.headers

      return call_next(context) unless headers.has_key?(FORWARDED_FOR)

      ips = headers[FORWARDED_FOR].split(/\s*,\s*/)

      return forbidden(context) if headers.has_key?(CLIENT_IP) && !ips.includes?(headers[CLIENT_IP])
      return forbidden(context) if headers.has_key?(REAL_IP) && !ips.includes?(headers[REAL_IP])

      call_next(context)
    end
  end
end
