require "http"

module IntegrationHelpers
  # Helper method to create HTTP context for testing
  def create_context(method = "GET", path = "/", headers = HTTP::Headers.new, body : String? = nil)
    request = HTTP::Request.new(method, path, headers, body)
    io = IO::Memory.new
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    {context, io}
  end

  # Helper to read response output
  def get_response_body(context : HTTP::Server::Context, io : IO::Memory) : String
    context.response.close
    io.rewind
    full_response = io.gets_to_end

    # Extract body from HTTP response (after the empty line that separates headers from body)
    if body_start = full_response.index("\r\n\r\n")
      full_response[(body_start + 4)..]
    elsif body_start = full_response.index("\n\n")
      full_response[(body_start + 2)..]
    else
      full_response
    end
  end

  # Get response headers as a hash
  def get_response_headers(context : HTTP::Server::Context) : HTTP::Headers
    context.response.headers
  end

  # Create a chain of handlers for testing
  def create_handler_chain(handlers : Array(HTTP::Handler))
    handlers.each_with_index do |handler, index|
      handler.next = handlers[index + 1] if index < handlers.size - 1
    end
    handlers.first
  end

  # Create a mock next handler that tracks calls
  def create_next_handler(expected_calls = 1, response_body = "OK")
    call_count = 0
    next_handler = ->(context : HTTP::Server::Context) {
      call_count += 1
      context.response.print response_body
    }
    verify = -> { call_count.should eq(expected_calls) }
    {next_handler, verify}
  end

  # Create a mock WebSocket
  def create_mock_websocket : HTTP::WebSocket
    io = IO::Memory.new
    HTTP::WebSocket.new(io)
  end

  # Create temporary file for static file testing
  def with_temp_file(content : String, filename : String = "test.txt", &)
    dir = File.tempname("azu_test")
    Dir.mkdir_p(dir)

    begin
      filepath = File.join(dir, filename)
      File.write(filepath, content)
      yield dir, filepath
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # Create temporary directory structure for static file testing
  def with_temp_dir(files : Hash(String, String), &)
    dir = File.tempname("azu_test")
    Dir.mkdir_p(dir)

    begin
      files.each do |path, content|
        full_path = File.join(dir, path)
        Dir.mkdir_p(File.dirname(full_path))
        File.write(full_path, content)
      end
      yield dir
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # Assert response status code
  def assert_status(context : HTTP::Server::Context, expected : Int32)
    context.response.status_code.should eq(expected)
  end

  # Assert response header value
  def assert_header(context : HTTP::Server::Context, header : String, expected : String)
    context.response.headers[header].should eq(expected)
  end

  # Assert response header exists
  def assert_header_exists(context : HTTP::Server::Context, header : String)
    context.response.headers.has_key?(header).should be_true
  end

  # Assert response contains text
  def assert_body_contains(body : String, text : String)
    body.should contain(text)
  end

  # Create a request with remote address
  def create_context_with_remote_addr(method = "GET", path = "/", remote_addr = "127.0.0.1")
    headers = HTTP::Headers.new
    headers["REMOTE_ADDR"] = remote_addr
    create_context(method, path, headers)
  end

  # Wait for async operations to complete
  def wait_for_async(timeout = 1.second, &)
    start = Time.monotonic
    while Time.monotonic - start < timeout
      begin
        return if yield
      rescue
        # Continue waiting
      end
      sleep 0.01.seconds
    end
    raise "Timeout waiting for async operation"
  end
end

