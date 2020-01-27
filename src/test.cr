require "./azu"

class HelloWorld < Azu::Endpoint
  def call
    "Hello #{params["name"]}!"
  end
end

Azu.pipelines do
  build :web do
    # plug HTTP::LogHandler.new
  end
end

Azu.router do
  get :web, "/hello", HelloWorld
end

Azu::Server.start
