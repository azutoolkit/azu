require "http"
require "logger"
require "radix"
require "json"
require "colorize"

require "./azu/**"

module Azu
  include Server
  VERSION     = "0.1.0"
  CONFIG      = Configuration.new
  ENVIRONMENT = Environment.parse ENV.fetch("CRYSTAL_ENV", "development")

  def self.configure
    with CONFIG yield
  end

  def self.pipelines
    with CONFIG.pipelines yield
  end

  def self.router
    with CONFIG.router yield
  end

  def self.log
    CONFIG.log
  end

  def self.env
    ENVIRONMENT
  end
end
