require "../spec_helper"

describe Azu::Params::Multipart do
  describe "file upload optimization" do
    it "respects file size limits" do
      # Set up global config for testing
      original_max_size = Azu::CONFIG.upload.max_file_size
      original_temp_dir = Azu::CONFIG.upload.temp_dir

      begin
        Azu::CONFIG.upload.max_file_size = 1024_u64 # 1KB limit for testing
        Azu::CONFIG.upload.temp_dir = Dir.tempdir

        # Create mock upload that exceeds size limit
        large_content = "x" * 2048 # 2KB content
        mock_upload = MockUpload.new("test.txt", large_content)

        expect_raises(Azu::Params::FileUploadError, /exceeds maximum allowed size/) do
          Azu::Params::Multipart::File.new(mock_upload)
        end
      ensure
        # Restore original config
        Azu::CONFIG.upload.max_file_size = original_max_size
        Azu::CONFIG.upload.temp_dir = original_temp_dir
      end
    end

    it "creates files in configured temp directory" do
      temp_dir = Path[Dir.tempdir, "azu_test_uploads"].to_s
      Dir.mkdir_p(temp_dir)

      # Store original config
      original_temp_dir = Azu::CONFIG.upload.temp_dir
      original_max_size = Azu::CONFIG.upload.max_file_size

      begin
        Azu::CONFIG.upload.temp_dir = temp_dir
        Azu::CONFIG.upload.max_file_size = 10240_u64 # 10KB limit

        content = "Hello, World!"
        mock_upload = MockUpload.new("hello.txt", content)

        file = Azu::Params::Multipart::File.new(mock_upload)

        # Verify file is created in correct temp directory
        file.temp_path.should start_with(temp_dir)
        ::File.exists?(file.temp_path).should be_true

        # Verify content is correct
        file.file.rewind
        file.file.gets_to_end.should eq(content)

        # Clean up
        file.cleanup
        ::File.exists?(file.temp_path).should be_false
      ensure
        # Restore original config
        Azu::CONFIG.upload.temp_dir = original_temp_dir
        Azu::CONFIG.upload.max_file_size = original_max_size

        Dir.delete(temp_dir) if Dir.exists?(temp_dir)
      end
    end

    it "handles streaming upload with proper buffering" do
      # Store original config
      original_buffer_size = Azu::CONFIG.upload.buffer_size
      original_max_size = Azu::CONFIG.upload.max_file_size

      begin
        content = "A" * 16384 # 16KB content
        mock_upload = MockUpload.new("large.txt", content)

        Azu::CONFIG.upload.buffer_size = 1024        # 1KB buffer
        Azu::CONFIG.upload.max_file_size = 32768_u64 # 32KB limit

        file = Azu::Params::Multipart::File.new(mock_upload)

        # Verify file size is correct
        file.size.should eq(16384_u64)

        # Verify content integrity
        file.file.rewind
        file.file.gets_to_end.should eq(content)

        # Clean up
        file.cleanup
      ensure
        # Restore original config
        Azu::CONFIG.upload.buffer_size = original_buffer_size
        Azu::CONFIG.upload.max_file_size = original_max_size
      end
    end

    it "cleans up temp files on error" do
      temp_dir = Path[Dir.tempdir, "azu_error_test"].to_s
      Dir.mkdir_p(temp_dir)

      # Store original config
      original_temp_dir = Azu::CONFIG.upload.temp_dir
      original_max_size = Azu::CONFIG.upload.max_file_size

      begin
        Azu::CONFIG.upload.temp_dir = temp_dir
        Azu::CONFIG.upload.max_file_size = 100_u64 # Very small limit

        large_content = "x" * 200
        mock_upload = MockUpload.new("large.txt", large_content)

        # Should raise error and clean up temp file
        expect_raises(Azu::Params::FileUploadError) do
          Azu::Params::Multipart::File.new(mock_upload)
        end

        # Verify no temp files remain
        Dir.glob(Path[temp_dir, "azu_upload_*"].to_s).should be_empty
      ensure
        # Restore original config
        Azu::CONFIG.upload.temp_dir = original_temp_dir
        Azu::CONFIG.upload.max_file_size = original_max_size

        Dir.delete(temp_dir) if Dir.exists?(temp_dir)
      end
    end
  end

  describe "FileUploadError" do
    it "includes field name and filename in error" do
      error = Azu::Params::FileUploadError.new(
        "Test error",
        field_name: "avatar",
        filename: "photo.jpg"
      )

      error.message.should eq("Test error")
      error.field_name.should eq("avatar")
      error.filename.should eq("photo.jpg")
    end
  end
end

# Mock upload class for testing
private class MockUpload
  getter filename : String?
  getter headers : HTTP::Headers
  getter creation_time : Time?
  getter modification_time : Time?
  getter read_time : Time?
  getter size : UInt64?
  getter body : IO::Memory

  def initialize(@filename : String?, content : String)
    @headers = HTTP::Headers.new
    @headers["Content-Type"] = "text/plain"
    @creation_time = Time.utc
    @modification_time = Time.utc
    @read_time = Time.utc
    @size = content.bytesize.to_u64
    @body = IO::Memory.new(content)
  end
end
