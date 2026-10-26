require "../../spec_helper"
require "../../../src/azu/testing/testing"

private def set_cookies(*lines : String) : HTTP::Headers
  HTTP::Headers{"Set-Cookie" => lines.to_a}
end

describe Azu::Testing::CookieJar do
  describe "a cookie without a Path" do
    it "belongs to the directory of the request that set it" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=a"), "/auth/login")

      jar.header_for("/auth").should eq "token=a"
      jar.header_for("/auth/logout").should eq "token=a"
      jar.header_for("/session").should be_nil
      jar.header_for("/authors").should be_nil
    end

    it "goes to every path when a top-level page set it" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("a=1"), "/login")
      jar.absorb(set_cookies("b=2"), "/")

      jar.header_for("/deep/page").should eq "a=1; b=2"
    end

    it "is what a Path that does not start with a slash gives" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=a; Path=auth"), "/auth/login")

      jar.header_for("/auth/x").should eq "token=a"
      jar.header_for("/session").should be_nil
    end
  end

  it "matches paths the way RFC 6265 does" do
    jar = Azu::Testing::CookieJar.new
    jar.absorb(set_cookies("a=1; Path=/admin", "b=2; Path=/docs/"), "/")

    jar.header_for("/admin").should eq "a=1"
    jar.header_for("/admin/x").should eq "a=1"
    jar.header_for("/administrator").should be_nil
    jar.header_for("/docs/x").should eq "b=2"
    jar.header_for("/docs").should be_nil
  end

  describe "a name set for several paths" do
    it "holds one cookie per path and sends the longer path first" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=root; Path=/", "token=auth; Path=/auth"), "/")

      jar.header_for("/auth/login").should eq "token=auth; token=root"
      jar.header_for("/session").should eq "token=root"
    end

    it "reads as the shortest path's value, the one the app reads from a request that carries them all" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=auth"), "/auth/login")
      jar.absorb(set_cookies("token=root; Path=/"), "/")

      jar["token"].should eq "root"
      jar.to_h.should eq({"token" => "root"})
      HTTP::Cookies.from_client_headers(HTTP::Headers{"Cookie" => jar.header_for("/auth/x").not_nil!})["token"].value.should eq "root"
    end

    it "loses only the path the server expires" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=root; Path=/"), "/")
      jar.absorb(set_cookies("token=auth"), "/auth/login")
      jar.absorb(set_cookies("token=; Max-Age=0"), "/auth/logout")

      jar.header_for("/auth/login").should eq "token=root"
    end

    it "loses every path on #delete" do
      jar = Azu::Testing::CookieJar.new
      jar.absorb(set_cookies("token=root; Path=/", "token=auth; Path=/auth"), "/")
      jar.delete("token")

      jar.to_h.should be_empty
      jar.header_for("/auth/login").should be_nil
    end
  end

  it "sends cookies of one path oldest first, and a replaced cookie keeps its place" do
    jar = Azu::Testing::CookieJar.new
    jar.absorb(set_cookies("a=1", "b=2"), "/")
    jar.absorb(set_cookies("a=3"), "/")

    jar.header_for("/").should eq "a=3; b=2"
  end

  it "sets a cookie for every path with []=" do
    jar = Azu::Testing::CookieJar.new
    jar["sid"] = "x"

    jar.header_for("/any/where").should eq "sid=x"
  end
end
