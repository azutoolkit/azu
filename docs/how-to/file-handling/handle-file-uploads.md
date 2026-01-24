# How to Handle File Uploads

This guide shows you how to accept and process file uploads in Azu.

## Basic File Upload

Create a request contract for file uploads:

```crystal
struct UploadRequest
  include Azu::Request

  getter file : HTTP::FormData::File
  getter description : String?

  def initialize(@file, @description = nil)
  end
end

struct UploadEndpoint
  include Azu::Endpoint(UploadRequest, UploadResponse)

  post "/upload"

  def call : UploadResponse
    file = upload_request.file

    # Access file properties
    filename = file.filename      # Original filename
    content = file.body           # File content as IO
    content_type = file.headers["Content-Type"]?

    # Save the file
    save_path = File.join("uploads", filename)
    File.write(save_path, content.gets_to_end)

    UploadResponse.new(filename, save_path)
  end
end
```

## HTML Form

```html
<form action="/upload" method="POST" enctype="multipart/form-data">
  <input type="file" name="file" required>
  <input type="text" name="description" placeholder="Description">
  <button type="submit">Upload</button>
</form>
```

## Multiple File Uploads

```crystal
struct MultiUploadRequest
  include Azu::Request

  getter files : Array(HTTP::FormData::File)

  def initialize(@files = [] of HTTP::FormData::File)
  end
end

struct MultiUploadEndpoint
  include Azu::Endpoint(MultiUploadRequest, MultiUploadResponse)

  post "/upload-multiple"

  def call : MultiUploadResponse
    saved_files = multi_upload_request.files.map do |file|
      save_path = save_file(file)
      {filename: file.filename, path: save_path}
    end

    MultiUploadResponse.new(saved_files)
  end

  private def save_file(file) : String
    filename = generate_unique_filename(file.filename)
    path = File.join("uploads", filename)
    File.write(path, file.body.gets_to_end)
    path
  end

  private def generate_unique_filename(original : String) : String
    ext = File.extname(original)
    "#{UUID.random}#{ext}"
  end
end
```

## File Size Limits

Validate file size:

```crystal
struct UploadRequest
  include Azu::Request

  MAX_SIZE = 10 * 1024 * 1024  # 10 MB

  getter file : HTTP::FormData::File

  def initialize(@file)
  end

  def validate
    super

    if file.body.size > MAX_SIZE
      errors << Error.new(:file, "must be smaller than 10 MB")
    end
  end
end
```

## Secure File Handling

Sanitize filenames and validate content:

```crystal
module FileUploader
  ALLOWED_EXTENSIONS = [".jpg", ".jpeg", ".png", ".gif", ".pdf"]
  UPLOAD_DIR = "uploads"

  def self.save(file : HTTP::FormData::File) : String
    # Sanitize filename
    original = file.filename || "unnamed"
    extension = File.extname(original).downcase
    safe_name = "#{UUID.random}#{extension}"

    # Validate extension
    unless ALLOWED_EXTENSIONS.includes?(extension)
      raise "Invalid file type"
    end

    # Ensure upload directory exists
    Dir.mkdir_p(UPLOAD_DIR)

    # Save file
    path = File.join(UPLOAD_DIR, safe_name)
    File.write(path, file.body.gets_to_end)

    path
  end
end
```

## Image Upload with Processing

```crystal
struct ImageUploadEndpoint
  include Azu::Endpoint(ImageUploadRequest, ImageResponse)

  post "/images"

  def call : ImageResponse
    file = image_upload_request.file

    # Validate it's an image
    unless image?(file)
      raise Azu::Response::BadRequest.new("File must be an image")
    end

    # Save original
    original_path = save_file(file, "originals")

    # Create thumbnail (using external tool)
    thumb_path = create_thumbnail(original_path)

    ImageResponse.new(
      original: original_path,
      thumbnail: thumb_path
    )
  end

  private def image?(file) : Bool
    content_type = file.headers["Content-Type"]?
    return false unless content_type

    content_type.starts_with?("image/")
  end

  private def create_thumbnail(path : String) : String
    thumb_path = path.gsub("originals", "thumbnails")
    Dir.mkdir_p(File.dirname(thumb_path))

    # Use ImageMagick or similar
    Process.run("convert", [path, "-resize", "200x200", thumb_path])

    thumb_path
  end
end
```

## Cloud Storage Upload

Upload to S3 or compatible storage:

```crystal
require "awscr-s3"

module S3Uploader
  CLIENT = Awscr::S3::Client.new(
    region: ENV["AWS_REGION"],
    aws_access_key: ENV["AWS_ACCESS_KEY_ID"],
    aws_secret_key: ENV["AWS_SECRET_ACCESS_KEY"]
  )
  BUCKET = ENV["S3_BUCKET"]

  def self.upload(file : HTTP::FormData::File) : String
    key = "uploads/#{UUID.random}/#{file.filename}"

    CLIENT.put_object(
      bucket: BUCKET,
      object: key,
      body: file.body.gets_to_end,
      headers: {"Content-Type" => file.headers["Content-Type"]? || "application/octet-stream"}
    )

    "https://#{BUCKET}.s3.amazonaws.com/#{key}"
  end
end
```

## Progress Tracking

Track upload progress with JavaScript:

```javascript
const form = document.getElementById('upload-form');
const progress = document.getElementById('progress');

form.addEventListener('submit', async (e) => {
  e.preventDefault();

  const formData = new FormData(form);
  const xhr = new XMLHttpRequest();

  xhr.upload.addEventListener('progress', (e) => {
    if (e.lengthComputable) {
      const percent = (e.loaded / e.total) * 100;
      progress.style.width = percent + '%';
    }
  });

  xhr.open('POST', '/upload');
  xhr.send(formData);
});
```

## Cleanup Old Files

Schedule cleanup of old uploads:

```crystal
module FileCleanup
  def self.cleanup_old_files(max_age : Time::Span = 7.days)
    cutoff = Time.utc - max_age

    Dir.glob("uploads/**/*").each do |path|
      next if File.directory?(path)

      if File.info(path).modification_time < cutoff
        File.delete(path)
      end
    end
  end
end
```

## See Also

- [Validate File Types](validate-file-types.md)
