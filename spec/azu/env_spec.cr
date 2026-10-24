require "../spec_helper"
require "file_utils"

# Sets variables for the block and restores the process environment afterwards.
private def with_env(vars : Hash(String, String?), &)
  saved = vars.keys.to_h { |name| {name, ENV[name]?} }
  vars.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  begin
    yield
  ensure
    saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  end
end

private def with_dir(&)
  dir = File.tempname("azu-env")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Azu::Env do
  describe ".parse" do
    it "reads KEY=VALUE pairs, skipping blank lines and comments" do
      vars = Azu::Env.parse("# a comment\n\nA=1\n  B = two  \n#C=3\n")
      vars.should eq({"A" => "1", "B" => "two"})
    end

    it "accepts an export prefix" do
      Azu::Env.parse("export A=1\nexport  B=2\n").should eq({"A" => "1", "B" => "2"})
    end

    it "treats a variable named export as a name, not a prefix" do
      Azu::Env.parse("export=1").should eq({"export" => "1"})
    end

    it "cuts an unquoted value at a whitespace-preceded #" do
      Azu::Env.parse("A=value # note\nB=a#b\nC=#nothing\n").should eq({"A" => "value", "B" => "a#b", "C" => ""})
    end

    it "keeps single-quoted values literal" do
      Azu::Env.parse(%q(A='a $B "c" \n # d')).should eq({"A" => %q(a $B "c" \n # d)})
    end

    it "unescapes double-quoted values" do
      Azu::Env.parse(%q(A="line1\nline2\t\"q\" \\ back")).should eq({"A" => "line1\nline2\t\"q\" \\ back"})
    end

    it "keeps an unknown escape as written" do
      Azu::Env.parse(%q(A="\d+")).should eq({"A" => %q(\d+)})
    end

    it "reads multi-line quoted values" do
      Azu::Env.parse("A=\"one\ntwo\"\nB='x\ny'\nC=3\n").should eq({"A" => "one\ntwo", "B" => "x\ny", "C" => "3"})
    end

    it "allows a comment after a quoted value" do
      Azu::Env.parse(%(A="v" # note\nB=2)).should eq({"A" => "v", "B" => "2"})
    end

    it "does no interpolation or shell evaluation" do
      vars = Azu::Env.parse("A=$(echo hi)\nB=${A}\nC=`id`\nD=\"$HOME\"\n")
      vars.should eq({"A" => "$(echo hi)", "B" => "${A}", "C" => "`id`", "D" => "$HOME"})
    end

    it "handles CRLF line endings and a BOM" do
      Azu::Env.parse("﻿A=1\r\nB=\"x\"\r\n").should eq({"A" => "1", "B" => "x"})
    end

    it "lets a later assignment win" do
      Azu::Env.parse("A=1\nA=2").should eq({"A" => "2"})
    end

    it "accepts an empty value" do
      Azu::Env.parse("A=\nB=''").should eq({"A" => "", "B" => ""})
    end

    it "does not touch the process environment" do
      with_env({"AZU_ENV_SPEC_PARSE" => nil}) do
        Azu::Env.parse("AZU_ENV_SPEC_PARSE=1")
        ENV["AZU_ENV_SPEC_PARSE"]?.should be_nil
      end
    end

    it "raises a ParseError naming the origin and line, never the value" do
      error = expect_raises(Azu::Env::ParseError) { Azu::Env.parse("A=1\nnot a pair topsecret\n", "app.env") }
      error.line.should eq 2
      error.message.to_s.should contain("app.env:2")
      error.message.to_s.should_not contain("topsecret")
    end

    it "rejects invalid names" do
      expect_raises(Azu::Env::ParseError, /1:/) { Azu::Env.parse("1BAD=x") }
      expect_raises(Azu::Env::ParseError, /1:/) { Azu::Env.parse("A-B=x") }
    end

    it "rejects an unterminated quote and text after a quoted value" do
      error = expect_raises(Azu::Env::ParseError) { Azu::Env.parse("A=ok\nB=\"never closed\nC=3") }
      error.message.to_s.should contain(":2")
      expect_raises(Azu::Env::ParseError) { Azu::Env.parse(%(A="x" y)) }
    end

    it "rejects a NUL byte" do
      expect_raises(Azu::Env::ParseError) { Azu::Env.parse("A=a\0b") }
    end
  end

  describe ".load" do
    it "sets variables that are not in the process environment and returns their names" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_A=from-file\nAZU_ENV_SPEC_B=2\n")
        with_env({"AZU_ENV_SPEC_A" => nil, "AZU_ENV_SPEC_B" => nil}) do
          Azu::Env.load(path).should eq ["AZU_ENV_SPEC_A", "AZU_ENV_SPEC_B"]
          ENV["AZU_ENV_SPEC_A"].should eq "from-file"
          ENV["AZU_ENV_SPEC_B"].should eq "2"
        end
      end
    end

    it "never overrides a variable already in the process environment" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_A=from-file\n")
        with_env({"AZU_ENV_SPEC_A" => "from-process"}) do
          Azu::Env.load(path).should be_empty
          ENV["AZU_ENV_SPEC_A"].should eq "from-process"
        end
      end
    end

    it "treats an empty process variable as present" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_A=from-file\n")
        with_env({"AZU_ENV_SPEC_A" => ""}) do
          Azu::Env.load(path)
          ENV["AZU_ENV_SPEC_A"].should eq ""
        end
      end
    end

    it "overrides when asked to" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_A=from-file\n")
        with_env({"AZU_ENV_SPEC_A" => "from-process"}) do
          Azu::Env.load(path, override: true).should eq ["AZU_ENV_SPEC_A"]
          ENV["AZU_ENV_SPEC_A"].should eq "from-file"
        end
      end
    end

    it "does nothing when the file does not exist" do
      with_dir do |dir|
        Azu::Env.load(File.join(dir, "missing.env")).should be_empty
      end
    end

    it "raises a ParseError for a malformed file and sets nothing" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_A=1\ngarbage\n")
        with_env({"AZU_ENV_SPEC_A" => nil}) do
          expect_raises(Azu::Env::ParseError, /\.env:2/) { Azu::Env.load(path) }
          ENV["AZU_ENV_SPEC_A"]?.should be_nil
        end
      end
    end
  end

  describe ".load_all" do
    it "applies process env > .env.local > .env.<CRYSTAL_ENV> > .env" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "AZU_ENV_SPEC_P=base\nAZU_ENV_SPEC_Q=base\nAZU_ENV_SPEC_R=base\nAZU_ENV_SPEC_S=base\n")
        File.write(File.join(dir, ".env.staging"), "AZU_ENV_SPEC_P=staging\nAZU_ENV_SPEC_Q=staging\nAZU_ENV_SPEC_R=staging\n")
        File.write(File.join(dir, ".env.local"), "AZU_ENV_SPEC_P=local\nAZU_ENV_SPEC_Q=local\n")
        File.write(File.join(dir, ".env.production"), "AZU_ENV_SPEC_S=production-file\n")
        names = {"AZU_ENV_SPEC_P" => nil, "AZU_ENV_SPEC_Q" => "process", "AZU_ENV_SPEC_R" => nil, "AZU_ENV_SPEC_S" => nil, "CRYSTAL_ENV" => "staging"}
        with_env(names) do
          Azu::Env.load_all(dir)
          ENV["AZU_ENV_SPEC_P"].should eq "local"
          ENV["AZU_ENV_SPEC_Q"].should eq "process"
          ENV["AZU_ENV_SPEC_R"].should eq "staging"
          ENV["AZU_ENV_SPEC_S"].should eq "base"
        end
      end
    end

    it "takes CRYSTAL_ENV from the files when the process does not set it" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "CRYSTAL_ENV=staging\nAZU_ENV_SPEC_P=base\n")
        File.write(File.join(dir, ".env.staging"), "AZU_ENV_SPEC_P=staging\n")
        with_env({"CRYSTAL_ENV" => nil, "AZU_ENV_SPEC_P" => nil}) do
          Azu::Env.load_all(dir)
          ENV["AZU_ENV_SPEC_P"].should eq "staging"
        end
      end
    end

    it "defaults to the development environment file" do
      with_dir do |dir|
        File.write(File.join(dir, ".env.development"), "AZU_ENV_SPEC_P=dev\n")
        with_env({"CRYSTAL_ENV" => nil, "AZU_ENV_SPEC_P" => nil}) do
          Azu::Env.load_all(dir)
          ENV["AZU_ENV_SPEC_P"].should eq "dev"
        end
      end
    end

    it "ignores a CRYSTAL_ENV that would escape the directory" do
      with_dir do |dir|
        with_env({"CRYSTAL_ENV" => "../../etc/passwd"}) do
          Azu::Env.load_all(dir).should be_empty
        end
      end
    end

    it "does nothing in an empty directory" do
      with_dir { |dir| Azu::Env.load_all(dir).should be_empty }
    end
  end

  describe "accessors" do
    it "fetches a value, treating a blank value as unset" do
      with_env({"AZU_ENV_SPEC_A" => "x", "AZU_ENV_SPEC_B" => "  ", "AZU_ENV_SPEC_C" => nil}) do
        Azu::Env.fetch("AZU_ENV_SPEC_A").should eq "x"
        Azu::Env.fetch?("AZU_ENV_SPEC_B").should be_nil
        Azu::Env.fetch("AZU_ENV_SPEC_B", "fallback").should eq "fallback"
        Azu::Env.fetch("AZU_ENV_SPEC_C", "fallback").should eq "fallback"
        Azu::Env.fetch("AZU_ENV_SPEC_A", "fallback").should eq "x"
      end
    end

    it "raises a MissingError naming the variable" do
      with_env({"AZU_ENV_SPEC_C" => nil}) do
        error = expect_raises(Azu::Env::MissingError) { Azu::Env.fetch("AZU_ENV_SPEC_C") }
        error.message.to_s.should contain("AZU_ENV_SPEC_C is not set")
        error.names.should eq ["AZU_ENV_SPEC_C"]
      end
    end

    it "parses booleans" do
      {"true" => true, "1" => true, "YES" => true, "on" => true, "false" => false, "0" => false, "No" => false, "off" => false}.each do |text, expected|
        with_env({"AZU_ENV_SPEC_BOOL" => text}) { Azu::Env.bool("AZU_ENV_SPEC_BOOL").should eq expected }
      end
    end

    it "uses the default of bool when unset and refuses a bad value" do
      with_env({"AZU_ENV_SPEC_BOOL" => nil}) do
        Azu::Env.bool("AZU_ENV_SPEC_BOOL", true).should be_true
        expect_raises(Azu::Env::MissingError, /AZU_ENV_SPEC_BOOL/) { Azu::Env.bool("AZU_ENV_SPEC_BOOL") }
      end
      with_env({"AZU_ENV_SPEC_BOOL" => "maybe-secret"}) do
        error = expect_raises(Azu::Env::InvalidError, /AZU_ENV_SPEC_BOOL/) { Azu::Env.bool("AZU_ENV_SPEC_BOOL", false) }
        error.message.to_s.should_not contain("maybe-secret")
      end
    end

    it "parses integers" do
      with_env({"AZU_ENV_SPEC_INT" => " 42 ", "AZU_ENV_SPEC_NONE" => nil}) do
        Azu::Env.int("AZU_ENV_SPEC_INT").should eq 42
        Azu::Env.int("AZU_ENV_SPEC_NONE", 7).should eq 7
        expect_raises(Azu::Env::MissingError, /AZU_ENV_SPEC_NONE/) { Azu::Env.int("AZU_ENV_SPEC_NONE") }
      end
      with_env({"AZU_ENV_SPEC_INT" => "forty"}) do
        error = expect_raises(Azu::Env::InvalidError, /AZU_ENV_SPEC_INT/) { Azu::Env.int("AZU_ENV_SPEC_INT", 1) }
        error.message.to_s.should_not contain("forty")
      end
    end

    it "parses URLs without leaking credentials in errors" do
      with_env({"AZU_ENV_SPEC_URL" => "postgres://user:pw@db.local:5432/app", "AZU_ENV_SPEC_NONE" => nil}) do
        uri = Azu::Env.url("AZU_ENV_SPEC_URL")
        uri.scheme.should eq "postgres"
        uri.host.should eq "db.local"
        uri.port.should eq 5432
        Azu::Env.url("AZU_ENV_SPEC_NONE", "redis://localhost:6379").scheme.should eq "redis"
      end
      with_env({"AZU_ENV_SPEC_URL" => "user:hunter2 not a url"}) do
        error = expect_raises(Azu::Env::InvalidError, /AZU_ENV_SPEC_URL/) { Azu::Env.url("AZU_ENV_SPEC_URL") }
        error.message.to_s.should_not contain("hunter2")
      end
    end

    it "requires several names with one aggregated error" do
      with_env({"AZU_ENV_SPEC_A" => "x", "AZU_ENV_SPEC_B" => nil, "AZU_ENV_SPEC_C" => ""}) do
        Azu::Env.required("AZU_ENV_SPEC_A")
        error = expect_raises(Azu::Env::MissingError) { Azu::Env.required("AZU_ENV_SPEC_A", "AZU_ENV_SPEC_B", "AZU_ENV_SPEC_C") }
        error.names.should eq ["AZU_ENV_SPEC_B", "AZU_ENV_SPEC_C"]
        error.message.to_s.should contain("AZU_ENV_SPEC_B, AZU_ENV_SPEC_C")
        error.message.to_s.should_not contain("AZU_ENV_SPEC_A")
      end
    end
  end

  describe ".environment" do
    it "reads CRYSTAL_ENV, lowercased, defaulting to development" do
      with_env({"CRYSTAL_ENV" => nil}) do
        Azu::Env.environment.should eq "development"
        Azu::Env.production?.should be_false
      end
      with_env({"CRYSTAL_ENV" => "Production"}) do
        Azu::Env.environment.should eq "production"
        Azu::Env.production?.should be_true
      end
      with_env({"CRYSTAL_ENV" => ""}) { Azu::Env.environment.should eq "development" }
    end
  end

  describe ".secret" do
    before_each { Azu::Env.reset_generated_secrets! }

    it "returns the environment value" do
      with_env({"AZU_ENV_SPEC_SECRET" => "s3cr3t", "CRYSTAL_ENV" => "production"}) do
        Azu::Env.secret("AZU_ENV_SPEC_SECRET").should eq "s3cr3t"
      end
    end

    it "falls back to a random value outside production, stable for the process" do
      with_env({"AZU_ENV_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "development"}) do
        first = Azu::Env.secret("AZU_ENV_SPEC_SECRET")
        first.size.should be >= 32
        Azu::Env.secret("AZU_ENV_SPEC_SECRET").should eq first
        Azu::Env.reset_generated_secrets!
        Azu::Env.secret("AZU_ENV_SPEC_SECRET").should_not eq first
      end
    end

    it "treats a blank value as unset" do
      with_env({"AZU_ENV_SPEC_SECRET" => "", "CRYSTAL_ENV" => "test"}) do
        Azu::Env.secret("AZU_ENV_SPEC_SECRET").should_not be_empty
      end
    end

    it "raises in production when it is not set" do
      with_env({"AZU_ENV_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "production"}) do
        error = expect_raises(Azu::Env::MissingError) { Azu::Env.secret("AZU_ENV_SPEC_SECRET") }
        error.message.to_s.should contain("AZU_ENV_SPEC_SECRET is not set")
      end
    end

    it "takes the production flag explicitly" do
      with_env({"AZU_ENV_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "development"}) do
        expect_raises(Azu::Env::MissingError) { Azu::Env.secret("AZU_ENV_SPEC_SECRET", production: true) }
      end
    end
  end

  describe "redaction" do
    it "filters secret-looking names" do
      Azu::Env.redact("CSRF_SECRET", "abc").should eq "[FILTERED]"
      Azu::Env.redact("DB_PASSWORD", "abc").should eq "[FILTERED]"
      Azu::Env.redact("API_TOKEN", "abc").should eq "[FILTERED]"
      Azu::Env.redact("SIGNING_KEY", "abc").should eq "[FILTERED]"
      Azu::Env.redact("PORT", "4000").should eq "4000"
    end

    it "hides the password inside a URL" do
      Azu::Env.redact("DATABASE_URL", "postgres://app:hunter2@db/app").should eq "postgres://app:[FILTERED]@db/app"
      Azu::Env.redact("DATABASE_URL", "sqlite3://./db/app.db").should eq "sqlite3://./db/app.db"
    end

    it "redacts a whole hash" do
      Azu::Env.redacted({"A" => "1", "SESSION_SECRET" => "x"}).should eq({"A" => "1", "SESSION_SECRET" => "[FILTERED]"})
    end
  end

  describe "Azu::Configuration" do
    it "reads PORT, HOST and DATABASE_URL through Env" do
      with_env({"PORT" => "4321", "HOST" => "127.0.0.1", "DATABASE_URL" => "sqlite3://./x.db"}) do
        config = Azu::Configuration.new
        config.port.should eq 4321
        config.host.should eq "127.0.0.1"
        config.database.uri.should eq "sqlite3://./x.db"
      end
    end

    it "names the variable when PORT is not a number" do
      with_env({"PORT" => "http"}) do
        expect_raises(Azu::Env::InvalidError, /PORT is not an integer/) { Azu::Configuration.new }
      end
    end

    it "treats a blank CRYSTAL_ENV as development" do
      with_env({"CRYSTAL_ENV" => ""}) { Azu::Configuration.new.env.should eq Azu::Environment::Development }
    end
  end

  describe "requiring" do
    it "does not read any file or change the environment" do
      dir = File.tempname("azu-env-req")
      Dir.mkdir_p(dir)
      begin
        File.write(File.join(dir, ".env"), "AZU_ENV_REQ_CHECK=leaked\n")
        search = [File.expand_path("../../src", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
        output = IO::Memory.new
        error = IO::Memory.new
        main = File.join(dir, "main.cr")
        File.write(main, %(require "azu/env"\nputs ENV["AZU_ENV_REQ_CHECK"]?.inspect))
        status = Process.run("crystal", ["run", "--no-color", main], env: {"CRYSTAL_PATH" => search}, chdir: dir, output: output, error: error)
        fail "child failed:\n#{error}" unless status.success?
        output.to_s.strip.should eq "nil"
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
