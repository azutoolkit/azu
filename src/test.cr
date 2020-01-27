require "./azu"

class HelloWorld < Azu::Endpoint
  def call
    "Hello #{params["name"]}!"
  end
end

Azu.pipelines do
  build :web do
  end
end

Azu.router do
  add :web, Azu::Method::Get, "/hello", HelloWorld
end

Azu::Server.start
