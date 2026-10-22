module Azu
  abstract class Model
    # Pragmatic email check (RFC 5322 in full is not worth a regex).
    EMAIL_FORMAT = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
    URL_FORMAT   = /\Ahttps?:\/\/[^\s\/$.?#].[^\s]*\z/i
    UUID_FORMAT  = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  end
end
