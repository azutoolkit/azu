# How to Validate File Types

This guide shows you how to validate uploaded file types for security.

## Basic Extension Validation

Check file extensions:

```crystal
module FileValidator
  ALLOWED_IMAGES = [".jpg", ".jpeg", ".png", ".gif", ".webp"]
  ALLOWED_DOCUMENTS = [".pdf", ".doc", ".docx", ".txt"]

  def self.valid_image?(filename : String) : Bool
    ext = File.extname(filename).downcase
    ALLOWED_IMAGES.includes?(ext)
  end

  def self.valid_document?(filename : String) : Bool
    ext = File.extname(filename).downcase
    ALLOWED_DOCUMENTS.includes?(ext)
  end
end
```

## Content-Type Validation

Validate the declared content type:

```crystal
ALLOWED_CONTENT_TYPES = {
  "image/jpeg" => [".jpg", ".jpeg"],
  "image/png" => [".png"],
  "image/gif" => [".gif"],
  "application/pdf" => [".pdf"],
}

def valid_content_type?(file : HTTP::FormData::File) : Bool
  content_type = file.headers["Content-Type"]?
  return false unless content_type

  filename = file.filename || ""
  ext = File.extname(filename).downcase

  if allowed_exts = ALLOWED_CONTENT_TYPES[content_type]?
    allowed_exts.includes?(ext)
  else
    false
  end
end
```

## Magic Number Validation

Check file signatures (magic numbers) for true file type:

```crystal
module MagicNumber
  SIGNATURES = {
    jpeg: Bytes[0xFF, 0xD8, 0xFF],
    png: Bytes[0x89, 0x50, 0x4E, 0x47],
    gif: Bytes[0x47, 0x49, 0x46],
    pdf: Bytes[0x25, 0x50, 0x44, 0x46],
    zip: Bytes[0x50, 0x4B, 0x03, 0x04],
  }

  def self.detect(io : IO) : Symbol?
    buffer = Bytes.new(8)
    io.read(buffer)
    io.rewind  # Reset position

    SIGNATURES.each do |type, signature|
      if buffer[0, signature.size] == signature
        return type
      end
    end

    nil
  end

  def self.image?(io : IO) : Bool
    type = detect(io)
    [:jpeg, :png, :gif].includes?(type)
  end

  def self.pdf?(io : IO) : Bool
    detect(io) == :pdf
  end
end
```

## Comprehensive File Validation

Combine all validation methods:

```crystal
class FileValidationError < Exception; end

module SecureFileValidator
  ALLOWED_TYPES = {
    image: {
      extensions: [".jpg", ".jpeg", ".png", ".gif"],
      content_types: ["image/jpeg", "image/png", "image/gif"],
      magic_check: ->(io : IO) { MagicNumber.image?(io) }
    },
    document: {
      extensions: [".pdf"],
      content_types: ["application/pdf"],
      magic_check: ->(io : IO) { MagicNumber.pdf?(io) }
    }
  }

  def self.validate!(file : HTTP::FormData::File, type : Symbol)
    config = ALLOWED_TYPES[type]?
    raise FileValidationError.new("Unknown file type category") unless config

    filename = file.filename || "unknown"
    ext = File.extname(filename).downcase
    content_type = file.headers["Content-Type"]?

    # Check extension
    unless config[:extensions].includes?(ext)
      raise FileValidationError.new("Invalid file extension: #{ext}")
    end

    # Check content type
    unless content_type && config[:content_types].includes?(content_type)
      raise FileValidationError.new("Invalid content type: #{content_type}")
    end

    # Check magic number
    unless config[:magic_check].call(file.body)
      raise FileValidationError.new("File content does not match declared type")
    end

    true
  end
end
```

## Request Validation

Integrate with request contracts:

```crystal
struct ImageUploadRequest
  include Azu::Request

  ALLOWED_EXTENSIONS = [".jpg", ".jpeg", ".png", ".gif"]
  MAX_SIZE = 5 * 1024 * 1024  # 5 MB

  getter image : HTTP::FormData::File

  def initialize(@image)
  end

  def validate
    super

    validate_extension
    validate_size
    validate_content
  end

  private def validate_extension
    ext = File.extname(image.filename || "").downcase
    unless ALLOWED_EXTENSIONS.includes?(ext)
      errors << Error.new(:image, "must be JPG, PNG, or GIF")
    end
  end

  private def validate_size
    if image.body.size > MAX_SIZE
      errors << Error.new(:image, "must be smaller than 5 MB")
    end
  end

  private def validate_content
    unless MagicNumber.image?(image.body)
      errors << Error.new(:image, "is not a valid image file")
    end
  end
end
```

## Security Considerations

### Avoid Path Traversal

```crystal
def safe_filename(original : String) : String
  # Remove path components
  name = File.basename(original)

  # Remove dangerous characters
  name = name.gsub(/[^a-zA-Z0-9._-]/, "_")

  # Ensure it doesn't start with a dot
  name = "_#{name}" if name.starts_with?(".")

  # Add unique prefix
  "#{UUID.random}_#{name}"
end
```

### Prevent Double Extensions

```crystal
def validate_filename(name : String) : Bool
  # Reject double extensions like "file.php.jpg"
  parts = name.split(".")
  return false if parts.size > 2

  # Reject executable extensions anywhere
  dangerous = [".php", ".exe", ".sh", ".bat", ".cmd", ".js"]
  parts.none? { |p| dangerous.includes?(".#{p.downcase}") }
end
```

### Validate Image Dimensions

```crystal
def validate_image_dimensions(file : HTTP::FormData::File, max_width = 4096, max_height = 4096)
  # Use ImageMagick identify
  result = Process.run("identify", ["-format", "%wx%h", "-"], input: file.body)

  dimensions = result.output.to_s.strip.split("x")
  width = dimensions[0].to_i
  height = dimensions[1].to_i

  file.body.rewind

  width <= max_width && height <= max_height
end
```

## Virus Scanning

Integrate with ClamAV:

```crystal
module VirusScanner
  def self.scan(file_path : String) : Bool
    result = Process.run("clamscan", ["--no-summary", file_path])
    result.exit_code == 0  # 0 means no virus found
  end

  def self.scan_io(io : IO) : Bool
    # Save to temp file for scanning
    temp_path = File.tempname("scan")
    File.write(temp_path, io.gets_to_end)
    io.rewind

    result = scan(temp_path)
    File.delete(temp_path)
    result
  end
end
```

## See Also

- [Handle File Uploads](handle-file-uploads.md)
