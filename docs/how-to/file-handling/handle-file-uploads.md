---
description: Accept and process file uploads in Azu.
---

# Handle file uploads

## How uploads work

A `multipart/form-data` request is parsed before your endpoint runs:

- Every part that has a filename is streamed to a temporary file in `config.upload.temp_dir` (the system temp
  directory by default) and appears in `params.files`, a `Hash(String, Azu::Params::Multipart::File)` keyed by the
  **form field name**.
- Every other part is a plain form field, available from `params` (and from the request contract).
- A file larger than `config.upload.max_file_size` (10 MB by default) is refused with `413 Payload Too Large`;
  the same limit applies to a JSON or form body. A body that cannot be parsed answers `400`.

Uploads are not part of the request contract: declare the endpoint with `Azu::Request` (or a contract for the
other fields) and read the files from `params.files`.

An uploaded file offers:

| Method | Meaning |
|---|---|
| `filename : String?` | the name the client sent (untrusted) |
| `size : UInt64?` | bytes written to the temp file |
| `headers : HTTP::Headers` | the headers of the part, e.g. `Content-Type` (declared by the client, untrusted) |
| `file : ::File` | the temp file, rewound, for reading |
| `temp_path : String` | its path |
| `cleanup` | closes and deletes the temp file |

## Basic file upload

```crystal
require "uuid"

struct UploadResponse
  include Azu::Response

  def initialize(@name : String, @size : UInt64)
  end

  def render
    {name: @name, size: @size}.to_json
  end
end

struct UploadEndpoint
  include Azu::Endpoint(Azu::Request, UploadResponse)

  post "/upload"

  def call : UploadResponse
    content_type "application/json"
    upload = params.files["file"]? || raise error("File is required")

    begin
      Dir.mkdir_p("uploads")
      stored = File.join("uploads", "#{UUID.random}#{File.extname(upload.filename || "").downcase}")
      File.copy(upload.temp_path, stored)
      UploadResponse.new(stored, upload.size || 0_u64)
    ensure
      upload.cleanup
    end
  end
end
```

`error("File is required")` builds a `400` response error.

{% hint style="warning" %}
Always call `cleanup` once you are done with the temp file (`ensure` does it on every path).
{% endhint %}

A background task also deletes `azu_upload_*` files older than `config.upload.max_temp_age` (24 hours) every
`cleanup_interval` (1 hour), but it is a safety net. It removes only temp files: the files you copy out (to
`uploads/` above) are yours to expire.

## HTML form

```html
<form action="/upload" method="POST" enctype="multipart/form-data">
  <input type="file" name="file" required>
  <input type="text" name="description" placeholder="Description">
  <button type="submit">Upload</button>
</form>
```

## Multiple file uploads

`params.files` is keyed by field name, so one field name holds one file: if several parts share a name, the last
one wins, and the temp file of the replaced one is left for the background cleanup. Give each file input its own name (`photo1`, `photo2`) and iterate:

```crystal
struct MultiUploadResponse
  include Azu::Response

  def initialize(@names : Array(String))
  end

  def render
    {files: @names}.to_json
  end
end

struct MultiUploadEndpoint
  include Azu::Endpoint(Azu::Request, MultiUploadResponse)

  post "/upload-multiple"

  def call : MultiUploadResponse
    content_type "application/json"
    names = [] of String

    begin
      params.files.each do |field, upload|
        names << "#{field}: #{upload.filename}"
      end
    ensure
      params.files.each_value(&.cleanup)
    end

    MultiUploadResponse.new(names)
  end
end
```

## File size limits

The limit is part of the upload configuration. It applies to each file as it is streamed, so an oversized file is
stopped after `max_file_size` bytes and its temp file is removed:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.upload.max_file_size = 5_u64 * 1024 * 1024
    config.upload.temp_dir = "/tmp/uploads"
  end
end
```

A multipart request has limits of its own, checked while the body streams in, so a client that sends more is cut off
after the limit and never fills the disk: `config.upload.max_request_size` (the whole request, 64 MB by default; a
`Content-Length` over it is refused before a byte is read), `max_parts` (100: fields and files together) and
`max_files` (20). A request over any of them is answered `413` and its temp files are removed. Raise them for an app that
takes many or big files, together with `max_file_size`:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.upload.max_file_size = 50_u64 * 1024 * 1024
    config.upload.max_request_size = 200_u64 * 1024 * 1024
    config.upload.max_files = 50
  end
end
```

Temp files are created with mode `0600` and a name the client cannot choose (its file name is only a hint in the name,
reduced to safe characters; `file.filename` keeps the original), and **they are deleted when the request is done**: copy
the file you want to keep inside the endpoint, as the examples do, and do not hand `temp_path` to a background job.
A second file under the same field name replaces the first, but every file counts toward `max_files`. A limit of `0` (or
below) refuses every multipart request or file rather than switching the check off: raise limits, do not zero them. A
client that opens a request and then stalls holds the temp files it has sent until the connection closes; the
server's connection limits (`header_timeout`, `read_timeout`) bound that.

`UPLOAD_MAX_FILE_SIZE` (bytes), `UPLOAD_MAX_REQUEST_SIZE`, `UPLOAD_MAX_PARTS`, `UPLOAD_MAX_FILES`, `UPLOAD_TEMP_DIR`, `UPLOAD_BUFFER_SIZE`, `UPLOAD_CLEANUP_INTERVAL` and
`UPLOAD_MAX_TEMP_AGE` (seconds) set the same from the environment. Put a limit on the request in your reverse proxy
too (`client_max_body_size` in Nginx), so that the bytes never reach the application.

## Secure file handling

{% hint style="danger" %}
Never use the client's file name as a path.
{% endhint %}

Pick the stored name yourself and keep only a vetted extension:

```crystal
require "uuid"

module FileUploader
  ALLOWED_EXTENSIONS = [".jpg", ".jpeg", ".png", ".gif", ".pdf"]
  UPLOAD_DIR         = "uploads"

  def self.save(upload : Azu::Params::Multipart::File) : String
    extension = File.extname(upload.filename || "").downcase
    raise Azu::Response::BadRequest.new("Invalid file type") unless ALLOWED_EXTENSIONS.includes?(extension)

    Dir.mkdir_p(UPLOAD_DIR)
    path = File.join(UPLOAD_DIR, "#{UUID.random}#{extension}")
    File.copy(upload.temp_path, path)
    path
  end
end
```

See [Validate File Types](validate-file-types.md) for checking the content, not only the name.

## Cloud storage upload

Azu does not ship a storage client. Use the client of your storage service and give it the temp file as an `IO`
(`upload.file`) so the content is streamed instead of read into memory, then call `upload.cleanup`.

## See also

- [Validate File Types](validate-file-types.md)
- [Handle Parameters](../endpoints/handle-parameters.md)
