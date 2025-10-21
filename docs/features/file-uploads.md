# File Uploads

Azu provides comprehensive file upload handling with support for multiple file types, validation, storage backends, and security features. Built-in support for multipart form data, file type validation, and secure file handling make file uploads straightforward and secure.

## What are File Uploads?

File uploads in Azu provide:

- **Multipart Form Support**: Handle multipart/form-data requests
- **File Validation**: Type, size, and content validation
- **Secure Storage**: Safe file storage with path sanitization
- **Progress Tracking**: Upload progress monitoring
- **Multiple Backends**: Local, cloud, and custom storage options

## Basic File Upload

### Simple File Upload Endpoint

```crystal
struct FileUploadEndpoint
  include Azu::Endpoint(FileUploadRequest, FileUploadResponse)

  post "/upload"

  def call : FileUploadResponse
    # Validate request
    unless file_upload_request.valid?
      raise Azu::Response::ValidationError.new(
        file_upload_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Process file upload
    file = file_upload_request.file
    filename = sanitize_filename(file.filename)
    file_path = save_file(file, filename)

    FileUploadResponse.new({
      filename: filename,
      file_path: file_path,
      size: file.size,
      content_type: file.content_type
    })
  end

  private def sanitize_filename(filename : String) : String
    # Remove dangerous characters
    filename.gsub(/[^a-zA-Z0-9._-]/, "_")
  end

  private def save_file(file : HTTP::FormData::File, filename : String) : String
    # Generate unique filename
    unique_filename = "#{Time.utc.to_unix}_#{filename}"
    file_path = File.join("uploads", unique_filename)

    # Ensure directory exists
    FileUtils.mkdir_p(File.dirname(file_path))

    # Save file
    File.write(file_path, file.content)

    file_path
  end
end
```

### File Upload Request Contract

```crystal
struct FileUploadRequest
  include Azu::Request

  getter file : HTTP::FormData::File
  getter description : String?

  def initialize(@file = HTTP::FormData::File.new("", "", "", 0), @description = nil)
  end

  # File validation
  validate file, presence: true, file_type: ["image/jpeg", "image/png", "image/gif", "application/pdf"]
  validate file, file_size: {max: 10.megabytes}
  validate description, length: {max: 500}, allow_nil: true
end
```

## File Validation

### File Type Validation

```crystal
struct ImageUploadRequest
  include Azu::Request

  getter image : HTTP::FormData::File

  def initialize(@image = HTTP::FormData::File.new("", "", "", 0))
  end

  # Validate image file types
  validate image, presence: true, file_type: ["image/jpeg", "image/png", "image/gif", "image/webp"]

  # Validate file size
  validate image, file_size: {max: 5.megabytes}

  # Custom validation for image dimensions
  validate image, custom: :validate_image_dimensions

  private def validate_image_dimensions
    return if @image.content.empty?

    begin
      # Check image dimensions
      dimensions = get_image_dimensions(@image.content)

      if dimensions[:width] > 4000 || dimensions[:height] > 4000
        errors.add("image", "Image dimensions too large")
      end

      if dimensions[:width] < 100 || dimensions[:height] < 100
        errors.add("image", "Image dimensions too small")
      end
    rescue e
      errors.add("image", "Invalid image file")
    end
  end

  private def get_image_dimensions(content : Bytes) : {width: Int32, height: Int32}
    # Implement image dimension detection
    # This would use an image processing library
    {width: 1000, height: 1000}
  end
end
```

### File Size Validation

```crystal
struct DocumentUploadRequest
  include Azu::Request

  getter document : HTTP::FormData::File

  def initialize(@document = HTTP::FormData::File.new("", "", "", 0))
  end

  # Validate document file types
  validate document, presence: true, file_type: ["application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"]

  # Validate file size (10MB max)
  validate document, file_size: {max: 10.megabytes}

  # Custom validation for PDF content
  validate document, custom: :validate_pdf_content

  private def validate_pdf_content
    return if @document.content.empty?

    # Check if file is actually a PDF
    unless @document.content.starts_with?("%PDF")
      errors.add("document", "File is not a valid PDF")
    end
  end
end
```

## File Storage

### Local Storage

```crystal
class LocalFileStorage
  def initialize(@upload_dir : String = "uploads")
    @upload_dir = @upload_dir
    FileUtils.mkdir_p(@upload_dir)
  end

  def store(file : HTTP::FormData::File, filename : String) : String
    # Generate unique filename
    unique_filename = generate_unique_filename(filename)
    file_path = File.join(@upload_dir, unique_filename)

    # Save file
    File.write(file_path, file.content)

    file_path
  end

  def retrieve(file_path : String) : Bytes?
    return nil unless File.exists?(file_path)
    File.read(file_path)
  end

  def delete(file_path : String) : Bool
    return false unless File.exists?(file_path)
    File.delete(file_path)
    true
  end

  private def generate_unique_filename(filename : String) : String
    extension = File.extname(filename)
    base_name = File.basename(filename, extension)
    timestamp = Time.utc.to_unix
    random = Random.rand(10000)

    "#{base_name}_#{timestamp}_#{random}#{extension}"
  end
end
```

### Cloud Storage

```crystal
class CloudFileStorage
  def initialize(@bucket : String, @region : String)
    @bucket = @bucket
    @region = @region
  end

  def store(file : HTTP::FormData::File, filename : String) : String
    # Generate unique filename
    unique_filename = generate_unique_filename(filename)

    # Upload to cloud storage
    upload_to_cloud(file.content, unique_filename)

    # Return public URL
    "https://#{@bucket}.s3.#{@region}.amazonaws.com/#{unique_filename}"
  end

  def retrieve(file_url : String) : Bytes?
    # Download from cloud storage
    download_from_cloud(file_url)
  end

  def delete(file_url : String) : Bool
    # Delete from cloud storage
    delete_from_cloud(file_url)
  end

  private def upload_to_cloud(content : Bytes, filename : String)
    # Implement cloud upload
    # This would use AWS SDK or similar
  end

  private def download_from_cloud(url : String) : Bytes?
    # Implement cloud download
    nil
  end

  private def delete_from_cloud(url : String) : Bool
    # Implement cloud deletion
    true
  end
end
```

## File Processing

### Image Processing

```crystal
class ImageProcessor
  def process_image(file : HTTP::FormData::File, filename : String) : ProcessedImage
    # Resize image
    resized = resize_image(file.content, 800, 600)

    # Generate thumbnail
    thumbnail = generate_thumbnail(file.content, 200, 200)

    # Save processed images
    resized_path = save_processed_image(resized, "resized_#{filename}")
    thumbnail_path = save_processed_image(thumbnail, "thumb_#{filename}")

    ProcessedImage.new(
      original: file.content,
      resized: resized,
      thumbnail: thumbnail,
      resized_path: resized_path,
      thumbnail_path: thumbnail_path
    )
  end

  private def resize_image(content : Bytes, width : Int32, height : Int32) : Bytes
    # Implement image resizing
    # This would use an image processing library
    content
  end

  private def generate_thumbnail(content : Bytes, width : Int32, height : Int32) : Bytes
    # Implement thumbnail generation
    content
  end

  private def save_processed_image(content : Bytes, filename : String) : String
    file_path = File.join("uploads", "processed", filename)
    FileUtils.mkdir_p(File.dirname(file_path))
    File.write(file_path, content)
    file_path
  end
end
```

### Document Processing

```crystal
class DocumentProcessor
  def process_document(file : HTTP::FormData::File, filename : String) : ProcessedDocument
    # Extract text content
    text_content = extract_text(file.content)

    # Generate preview
    preview = generate_preview(file.content)

    # Save processed document
    text_path = save_text_content(text_content, "text_#{filename}")
    preview_path = save_preview(preview, "preview_#{filename}")

    ProcessedDocument.new(
      original: file.content,
      text_content: text_content,
      preview: preview,
      text_path: text_path,
      preview_path: preview_path
    )
  end

  private def extract_text(content : Bytes) : String
    # Implement text extraction
    # This would use a document processing library
    "Extracted text content"
  end

  private def generate_preview(content : Bytes) : Bytes
    # Implement preview generation
    content
  end

  private def save_text_content(text : String, filename : String) : String
    file_path = File.join("uploads", "text", filename)
    FileUtils.mkdir_p(File.dirname(file_path))
    File.write(file_path, text)
    file_path
  end

  private def save_preview(content : Bytes, filename : String) : String
    file_path = File.join("uploads", "previews", filename)
    FileUtils.mkdir_p(File.dirname(file_path))
    File.write(file_path, content)
    file_path
  end
end
```

## Security Features

### File Type Validation

```crystal
class SecureFileUpload
  def self.validate_file_type(file : HTTP::FormData::File, allowed_types : Array(String)) : Bool
    # Check MIME type
    unless allowed_types.includes?(file.content_type)
      return false
    end

    # Check file signature
    unless validate_file_signature(file.content, file.content_type)
      return false
    end

    true
  end

  private def self.validate_file_signature(content : Bytes, content_type : String) : Bool
    case content_type
    when "image/jpeg"
      content.starts_with?([0xFF, 0xD8, 0xFF])
    when "image/png"
      content.starts_with?([0x89, 0x50, 0x4E, 0x47])
    when "application/pdf"
      content.starts_with?("%PDF")
    else
      true
    end
  end
end
```

### Path Traversal Protection

```crystal
class SecureFileStorage
  def store(file : HTTP::FormData::File, filename : String) : String
    # Sanitize filename
    safe_filename = sanitize_filename(filename)

    # Generate secure path
    secure_path = generate_secure_path(safe_filename)

    # Save file
    File.write(secure_path, file.content)

    secure_path
  end

  private def sanitize_filename(filename : String) : String
    # Remove path traversal attempts
    filename = filename.gsub(/\.\./, "")
    filename = filename.gsub(/[\/\\]/, "_")
    filename = filename.gsub(/[^a-zA-Z0-9._-]/, "_")
    filename
  end

  private def generate_secure_path(filename : String) : String
    # Generate secure directory structure
    timestamp = Time.utc.to_unix
    random = Random.rand(10000)
    secure_dir = File.join("uploads", "#{timestamp}", "#{random}")

    FileUtils.mkdir_p(secure_dir)
    File.join(secure_dir, filename)
  end
end
```

## Progress Tracking

### Upload Progress

```crystal
class UploadProgressTracker
  def initialize(@upload_id : String)
    @upload_id = @upload_id
    @progress = 0.0
    @status = "uploading"
  end

  def update_progress(progress : Float64)
    @progress = progress
    @status = progress >= 100.0 ? "completed" : "uploading"

    # Store progress in cache
    Azu.cache.set("upload:#{@upload_id}:progress", {
      progress: @progress,
      status: @status,
      timestamp: Time.utc.to_rfc3339
    }.to_json, ttl: 1.hour)
  end

  def get_progress : Hash(String, JSON::Any)
    if cached = Azu.cache.get("upload:#{@upload_id}:progress")
      JSON.parse(cached).as_h
    else
      {
        "progress" => JSON::Any.new(0.0),
        "status" => JSON::Any.new("unknown"),
        "timestamp" => JSON::Any.new(Time.utc.to_rfc3339)
      }
    end
  end
end
```

### WebSocket Progress Updates

```crystal
class UploadProgressChannel < Azu::Channel
  ws "/upload_progress"

  def on_connect
    send_to_client({
      type: "connected",
      message: "Connected to upload progress"
    })
  end

  def on_message(message : String)
    data = JSON.parse(message)

    case data["type"]?.try(&.as_s)
    when "subscribe"
      upload_id = data["upload_id"]?.try(&.as_s)
      subscribe_to_upload_progress(upload_id)
    end
  end

  private def subscribe_to_upload_progress(upload_id : String)
    # Monitor upload progress
    spawn monitor_upload_progress(upload_id)
  end

  private def monitor_upload_progress(upload_id : String)
    loop do
      progress = UploadProgressTracker.new(upload_id).get_progress

      send_to_client({
        type: "progress_update",
        upload_id: upload_id,
        progress: progress
      })

      break if progress["status"].as_s == "completed"
      sleep 1.second
    end
  end
end
```

## File Management

### File Metadata

```crystal
class FileMetadata
  property filename : String
  property content_type : String
  property size : Int64
  property uploaded_at : Time
  property file_path : String
  property checksum : String

  def initialize(@filename : String, @content_type : String, @size : Int64,
                 @file_path : String, @checksum : String)
    @uploaded_at = Time.utc
  end

  def to_json
    {
      filename: @filename,
      content_type: @content_type,
      size: @size,
      uploaded_at: @uploaded_at.to_rfc3339,
      file_path: @file_path,
      checksum: @checksum
    }.to_json
  end
end
```

### File Cleanup

```crystal
class FileCleanupService
  def self.cleanup_old_files
    # Find old files
    old_files = find_old_files(30.days)

    # Delete old files
    old_files.each do |file_path|
      File.delete(file_path) if File.exists?(file_path)
    end

    # Clean up metadata
    cleanup_old_metadata(30.days)
  end

  private def self.find_old_files(age : Time::Span) : Array(String)
    cutoff_time = Time.utc - age
    old_files = [] of String

    Dir.glob("uploads/**/*") do |file_path|
      if File.file?(file_path)
        file_time = File.info(file_path).modification_time
        if file_time < cutoff_time
          old_files << file_path
        end
      end
    end

    old_files
  end

  private def self.cleanup_old_metadata(age : Time::Span)
    # Clean up old metadata from cache
    # Implementation depends on cache backend
  end
end
```

## Testing File Uploads

### Unit Testing

```crystal
require "spec"

describe "File Upload" do
  it "validates file type" do
    request = FileUploadRequest.new(
      file: HTTP::FormData::File.new("test.jpg", "image/jpeg", "test content", 12)
    )

    request.valid?.should be_true
  end

  it "rejects invalid file type" do
    request = FileUploadRequest.new(
      file: HTTP::FormData::File.new("test.exe", "application/x-executable", "test content", 12)
    )

    request.valid?.should be_false
  end

  it "validates file size" do
    large_content = "x" * (11 * 1024 * 1024)  # 11MB
    request = FileUploadRequest.new(
      file: HTTP::FormData::File.new("test.jpg", "image/jpeg", large_content, large_content.size)
    )

    request.valid?.should be_false
  end
end
```

### Integration Testing

```crystal
describe "File Upload Integration" do
  it "handles complete upload process" do
    # Create test file
    test_content = "test file content"
    test_file = HTTP::FormData::File.new("test.txt", "text/plain", test_content, test_content.size)

    # Create request
    request = FileUploadRequest.new(file: test_file)

    # Process upload
    endpoint = FileUploadEndpoint.new
    response = endpoint.call

    # Verify response
    response.filename.should eq("test.txt")
    response.size.should eq(test_content.size)
    response.content_type.should eq("text/plain")
  end
end
```

## Best Practices

### 1. Validate File Types

```crystal
# Good: Validate file types
validate file, file_type: ["image/jpeg", "image/png", "image/gif"]

# Avoid: No file type validation
# No validation - security risk
```

### 2. Limit File Sizes

```crystal
# Good: Limit file sizes
validate file, file_size: {max: 10.megabytes}

# Avoid: No size limits
# No size limits - can cause memory issues
```

### 3. Sanitize Filenames

```crystal
# Good: Sanitize filenames
def sanitize_filename(filename : String) : String
  filename.gsub(/[^a-zA-Z0-9._-]/, "_")
end

# Avoid: Use raw filenames
# Raw filenames - security risk
```

### 4. Use Secure Storage

```crystal
# Good: Secure storage
def generate_secure_path(filename : String) : String
  timestamp = Time.utc.to_unix
  random = Random.rand(10000)
  File.join("uploads", "#{timestamp}", "#{random}", filename)
end

# Avoid: Predictable paths
# Predictable paths - security risk
```

### 5. Handle Errors Gracefully

```crystal
# Good: Handle errors
def upload_file(file : HTTP::FormData::File) : String?
  begin
    process_file(file)
  rescue e
    Log.error(exception: e) { "File upload failed" }
    nil
  end
end

# Avoid: Ignore errors
# Ignoring errors - can cause data loss
```

## Next Steps

Now that you understand file uploads:

1. **[Security](../advanced/security.md)** - Implement file upload security
2. **[Performance](../advanced/performance.md)** - Optimize file upload performance
3. **[Testing](../testing.md)** - Test file upload functionality
4. **[Deployment](../deployment/production.md)** - Deploy with file upload support
5. **[Monitoring](../advanced/monitoring.md)** - Monitor file upload performance

---

_File uploads in Azu provide a secure and efficient way to handle file uploads. With comprehensive validation, multiple storage backends, and security features, they make building file upload functionality straightforward and reliable._
