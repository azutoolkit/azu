# How to Validate File Types

This guide shows you how to validate uploaded file types for security. Everything the client sends about a file is
untrusted: the file name and the `Content-Type` of the part are chosen by the client. The only evidence you can
check yourself is the content.

Uploaded files arrive in `params.files` as `Azu::Params::Multipart::File` objects, already written to a temp file
(see [Handle File Uploads](handle-file-uploads.md)). The size limit is enforced before your endpoint runs:
set `config.upload.max_file_size`.

## Basic Extension Validation

Check file extensions:

```crystal
module FileValidator
  ALLOWED_IMAGES    = [".jpg", ".jpeg", ".png", ".gif", ".webp"]
  ALLOWED_DOCUMENTS = [".pdf", ".txt"]

  def self.valid_image?(filename : String?) : Bool
    ALLOWED_IMAGES.includes?(File.extname(filename || "").downcase)
  end

  def self.valid_document?(filename : String?) : Bool
    ALLOWED_DOCUMENTS.includes?(File.extname(filename || "").downcase)
  end
end
```

## Content-Type Validation

The declared content type must agree with the extension. This catches mistakes, not attacks, because the client
writes both:

```crystal
ALLOWED_CONTENT_TYPES = {
  "image/jpeg"      => [".jpg", ".jpeg"],
  "image/png"       => [".png"],
  "image/gif"       => [".gif"],
  "application/pdf" => [".pdf"],
}

def valid_content_type?(upload : Azu::Params::Multipart::File) : Bool
  content_type = upload.headers["Content-Type"]?
  return false unless content_type

  extension = File.extname(upload.filename || "").downcase
  allowed = ALLOWED_CONTENT_TYPES[content_type]?
  !allowed.nil? && allowed.includes?(extension)
end
```

## Magic Number Validation

Check the file signature (magic number), the first bytes of the content, for the true file type. Read from the temp file
and rewind so that the file can be read again afterwards. The `MagicNumber` module is the first part of the example in
the next section.

## Comprehensive File Validation

Combine the checks. A failure raises `Azu::Response::ValidationError`, which `Azu::Handler::Rescuer` answers with `422`
and the field name. The endpoint validates, then keeps the file under a name you chose, and removes the temp file on
every path:

```crystal
require "uuid"

module MagicNumber
  SIGNATURES = {
    jpeg: Bytes[0xFF, 0xD8, 0xFF],
    png:  Bytes[0x89, 0x50, 0x4E, 0x47],
    gif:  Bytes[0x47, 0x49, 0x46],
    pdf:  Bytes[0x25, 0x50, 0x44, 0x46],
    zip:  Bytes[0x50, 0x4B, 0x03, 0x04],
  }

  def self.detect(io : IO) : Symbol?
    buffer = Bytes.new(8)
    count = io.read(buffer)
    io.rewind

    SIGNATURES.each do |type, signature|
      return type if count >= signature.size && buffer[0, signature.size] == signature
    end
    nil
  end

  def self.image?(io : IO) : Bool
    [:jpeg, :png, :gif].includes?(detect(io))
  end

  def self.pdf?(io : IO) : Bool
    detect(io) == :pdf
  end
end

module SecureFileValidator
  record Kind, extensions : Array(String), content_types : Array(String), signature : Proc(IO, Bool)

  KINDS = {
    image: Kind.new(
      [".jpg", ".jpeg", ".png", ".gif"],
      ["image/jpeg", "image/png", "image/gif"],
      ->(io : IO) { MagicNumber.image?(io) }
    ),
    document: Kind.new(
      [".pdf"],
      ["application/pdf"],
      ->(io : IO) { MagicNumber.pdf?(io) }
    ),
  }

  def self.validate!(field : String, upload : Azu::Params::Multipart::File, type : Symbol) : Nil
    kind = KINDS[type]? || raise ArgumentError.new("Unknown file kind #{type}")

    extension = File.extname(upload.filename || "").downcase
    reject(field, "has an invalid extension") unless kind.extensions.includes?(extension)

    declared = upload.headers["Content-Type"]?
    reject(field, "has an invalid content type") unless declared && kind.content_types.includes?(declared)

    reject(field, "does not match its declared type") unless kind.signature.call(upload.file)
  end

  private def self.reject(field : String, message : String)
    raise Azu::Response::ValidationError.new(field, message)
  end
end

struct AvatarResponse
  include Azu::Response

  def initialize(@path : String)
  end

  def render
    {path: @path}.to_json
  end
end

struct AvatarEndpoint
  include Azu::Endpoint(Azu::Request, AvatarResponse)

  post "/avatar"

  def call : AvatarResponse
    content_type "application/json"
    upload = params.files["image"]? || raise Azu::Response::ValidationError.new("image", "is required")

    begin
      SecureFileValidator.validate!("image", upload, :image)

      Dir.mkdir_p("uploads")
      path = File.join("uploads", "#{UUID.random}#{File.extname(upload.filename || "").downcase}")
      File.copy(upload.temp_path, path)
      AvatarResponse.new(path)
    ensure
      upload.cleanup
    end
  end
end
```

A file that is too large never gets to the endpoint: it is refused with `413` while it is being received. To allow a
smaller limit for one endpoint, check `upload.size` and raise `Azu::Response::PayloadTooLarge`.

## Security Considerations

### Avoid Path Traversal

Do not build a path from the client's file name. If you must keep it, reduce it to a safe form:

```crystal
require "uuid"

def safe_filename(original : String) : String
  name = File.basename(original.gsub('\\', '/'))
  name = name.gsub(/[^a-zA-Z0-9._-]/, "_")
  name = "_#{name}" if name.starts_with?(".")
  "#{UUID.random}_#{name}"
end
```

### Prevent Double Extensions

Reject names such as `file.php.jpg` when your server might execute the inner extension:

```crystal
def valid_filename?(name : String) : Bool
  parts = name.split(".")
  return false if parts.size > 2

  dangerous = [".php", ".exe", ".sh", ".bat", ".cmd", ".js"]
  parts.none? { |part| dangerous.includes?(".#{part.downcase}") }
end
```

Serving uploads from a directory that is not executable, with a content type you set, is the stronger defence.

## Virus Scanning

The temp file has a path, so an external scanner can read it. With ClamAV installed:

```crystal
module VirusScanner
  def self.clean?(path : String) : Bool
    Process.run("clamscan", ["--no-summary", path]).success?
  end
end
```

`clamscan` exits with `0` when nothing was found.

## See Also

- [Handle File Uploads](handle-file-uploads.md)
