require "./azu"

class HelloWorld < Azu::Endpoint
  def call
    "Hello #{params["name"]}!"
  end
end

Azu.pipelines do
  build :web do
    plug Azu::LogHandler.new(Azu.log)
  end
end

Azu.router do
  get :web, "/hello", HelloWorld
end

Azu::Server.start
