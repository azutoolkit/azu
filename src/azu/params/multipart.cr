module Multipart
  struct File
    getter file : ::File
    getter filename : String?
    getter headers : HTTP::Headers
    getter creation_time : Time?
    getter modification_time : Time?
    getter read_time : Time?
    getter size : UInt64?

    def initialize(upload)
      @filename = upload.filename
      @file = ::File.tempfile(filename)
      ::File.open(@file.path, "w") do |f|
        ::IO.copy(upload.body, f)
      end
      @headers = upload.headers
      @creation_time = upload.creation_time
      @modification_time = upload.modification_time
      @read_time = upload.read_time
      @size = upload.size
    end
  end

  def self.parse(request : HTTP::Request)
    multipart_params = Azu::Types::Params.new
    files = Azu::Types::Files.new

    HTTP::FormData.parse(request) do |upload|
      next unless upload
      filename = upload.filename
      if filename.is_a?(String) && !filename.empty?
        files[upload.name] = File.new(upload: upload)
      else
        multipart_params[upload.name] = upload.body.gets_to_end
      end
    end
    {multipart_params, files}
  end
end
