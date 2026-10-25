require "../spec_helper"
require "file_utils"
require "log/spec"
require "digest/sha256"

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

  describe "the shared parser corpus" do
    # spec/fixtures/dotenv_corpus.json is identical in azu and azu_cli (whose AzuCLI::DotEnv copies this parser):
    # change one, change both.
    path = File.join(__DIR__, "../fixtures/dotenv_corpus.json")
    corpus = JSON.parse(File.read(path)).as_a

    it "is the corpus azu_cli pins (same SHA256 in azu_cli's spec/azu_cli/dot_env_spec.cr)" do
      corpus.size.should be > 0
      Digest::SHA256.hexdigest(File.read(path)).should eq "67bad3660aca88d0600542f9f9587b3d5545d963872c290cf054470ef6594a2e"
    end

    corpus.each do |entry|
      it entry["name"].as_s do
        input = entry["input"].as_s
        if line = entry["error_line"]?
          error = expect_raises(Azu::Env::ParseError) { Azu::Env.parse(input) }
          error.line.should eq line.as_i
        else
          expected = entry["expect"].as_h.transform_values(&.as_s)
          Azu::Env.parse(input).should eq expected
        end
      end
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

  describe "untrusted files" do
    it "skips variables that change how processes start, with a warning naming them and never the value" do
      names = %w[LD_PRELOAD ld_library_path DYLD_INSERT_LIBRARIES PATH SHELL IFS BASH_ENV ENV SHARDS_CACHE_PATH SHARDS_INSTALL_PATH
        CRYSTAL_PATH CRYSTAL_OPTS CRYSTAL_LIBRARY_PATH GIT_SSH_COMMAND GIT_DIR DOCKER_HOST HOME path]
      names.each { |name| Azu::Env.unsafe_name?(name).should be_true }
      %w[PORT DATABASE_URL CSRF_SECRET PATHS SHELLY MY_PATH CRYSTAL_ENV GITHUB_TOKEN].each { |name| Azu::Env.unsafe_name?(name).should be_false }
    end

    it "does not load them from a file, but loads the rest" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_OK=1\nLD_PRELOAD=/tmp/evil.so\nGIT_SSH_COMMAND=evil-secret-value\nSHARDS_CACHE_PATH=/tmp/x\n")
        with_env({"AZU_ENV_SPEC_OK" => nil, "LD_PRELOAD" => nil, "GIT_SSH_COMMAND" => nil, "SHARDS_CACHE_PATH" => nil}) do
          Log.capture("azu.env") do |logs|
            Azu::Env.load(path).should eq ["AZU_ENV_SPEC_OK"]
            logs.check(:warn, /LD_PRELOAD/)
            logs.check(:warn, /GIT_SSH_COMMAND/)
            logs.entry.message.should_not contain("evil")
          end
          ENV["LD_PRELOAD"]?.should be_nil
          ENV["GIT_SSH_COMMAND"]?.should be_nil
          ENV["SHARDS_CACHE_PATH"]?.should be_nil
        end
      end
    end

    it "applies the same rule to load_all, and unsafe: true bypasses it" do
      with_dir do |dir|
        File.write(File.join(dir, ".env.local"), "CRYSTAL_OPTS=--no-color\n")
        with_env({"CRYSTAL_OPTS" => nil}) do
          Azu::Env.load_all(dir).should be_empty
          ENV["CRYSTAL_OPTS"]?.should be_nil
          Azu::Env.load_all(dir, unsafe: true).should eq ["CRYSTAL_OPTS"]
          ENV["CRYSTAL_OPTS"].should eq "--no-color"
        end
      end
    end

    it "denies the toolchain, trust-redirection and locale families, in any case" do
      names = %w[CC CXX CPP CFLAGS CXXFLAGS LDFLAGS RUSTFLAGS GOFLAGS MAKEFLAGS LDLIBS LIBS AR AS LD COMPILER_PATH GCC_EXEC_PREFIX
        OBJC_INCLUDE_PATH SDKROOT DEVELOPER_DIR CPATH LIBRARY_PATH OPENSSL_CONF OPENSSL_MODULES SSL_CERT_FILE SSL_CERT_DIR
        CURL_CA_BUNDLE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY FTP_PROXY
        CURL_HOME WGETRC HOSTALIASES LOCALDOMAIN RES_OPTIONS PERLLIB PERLIO PERL5LIB RUBYOPT RUBYLIB LUA_PATH LUA_CPATH
        JAVA_TOOL_OPTIONS _JAVA_OPTIONS CLASSPATH GEM_HOME GEM_PATH BUNDLE_GEMFILE NPM_CONFIG_REGISTRY NODE_OPTIONS
        HOMEBREW_PREFIX GOPROXY CARGO_HOME CARGO_BUILD_RUSTC RUSTC_WRAPPER TERMINFO TERMINFO_DIRS TERMCAP MANPATH
        LANG LANGUAGE LC_ALL LC_CTYPE LOCALE_ARCHIVE TZ TZDIR MALLOC_CONF MALLOC_ARENA_MAX ARGV0 _ USER LOGNAME PWD OLDPWD
        USERPROFILE TMPDIR XDG_CONFIG_HOME PYTHONPATH PKG_CONFIG_PATH EDITOR SHELLOPTS PS4 PROMPT_COMMAND CDPATH GLIBC_TUNABLES
        CRYSTAL_WORKERS CRYSTAL_CACHE_DIR DOCKER_CONFIG COMPOSE_FILE SSH_AUTH_SOCK]
      names.each do |name|
        Azu::Env.unsafe_name?(name).should be_true
        Azu::Env.unsafe_name?(name.downcase).should be_true
      end
    end

    it "keeps application names, including CRYSTAL_ENV and CRYSTAL_LOG_*, loadable" do
      names = %w[PORT HOST DATABASE_URL REDIS_URL CSRF_SECRET SESSION_SECRET GITHUB_TOKEN CRYSTAL_ENV CRYSTAL_LOG_LEVEL
        CRYSTAL_LOG_SOURCES LANGUAGE_PACK CCACHE TZINFO USERNAME USER_ID FLAGSHIP AZU_STRICT_ENVS PATHS MY_PATH]
      names.each { |name| Azu::Env.unsafe_name?(name).should be_false }
    end

    it "skips a new family from a file with a warning naming it (never the value), and loads a safe name beside it" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "AZU_ENV_SPEC_OK=1\nCFLAGS=evil-value\nhttps_proxy=http://evil.example\nTZ=UTC\nLC_ALL=C\nGOPROXY=evil-value\n")
        names = %w[AZU_ENV_SPEC_OK CFLAGS https_proxy TZ LC_ALL GOPROXY]
        with_env(names.to_h { |name| {name, nil} }) do
          Log.capture("azu.env") do |logs|
            Azu::Env.load(path).should eq ["AZU_ENV_SPEC_OK"]
            %w[CFLAGS https_proxy TZ LC_ALL GOPROXY].each { |name| logs.check(:warn, /#{name}/) }
            logs.empty
          end
          (names - ["AZU_ENV_SPEC_OK"]).each { |name| ENV[name]?.should be_nil }
        end
      end
    end

    it "never puts a value in any warning" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "CFLAGS=evil-value\nhttps_proxy=http://evil.example\n")
        with_env({"CFLAGS" => nil, "https_proxy" => nil}) do
          Log.capture("azu.env") do |logs|
            Azu::Env.load_all(dir)
            %w[CFLAGS https_proxy].each do |name|
              logs.check(:warn, /#{name}/)
              logs.entry.message.should_not contain("evil")
            end
            logs.empty
          end
        end
      end
    end

    it "skips the new families with override: true too, for load and load_all" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "TZ=UTC\nCFLAGS=-O2\nAZU_ENV_SPEC_OK=1\n")
        with_env({"TZ" => "Europe/Paris", "CFLAGS" => nil, "AZU_ENV_SPEC_OK" => nil}) do
          Azu::Env.load(File.join(dir, ".env"), override: true).should eq ["AZU_ENV_SPEC_OK"]
          ENV["TZ"].should eq "Europe/Paris"
          ENV["CFLAGS"]?.should be_nil
          ENV.delete("AZU_ENV_SPEC_OK")
          Azu::Env.load_all(dir, override: true).should eq ["AZU_ENV_SPEC_OK"]
          ENV["TZ"].should eq "Europe/Paris"
          ENV["CFLAGS"]?.should be_nil
        end
      end
    end

    it "does not warn when the real environment already has the denied name" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "TZ=UTC\n")
        with_env({"TZ" => "Europe/Paris"}) do
          Log.capture("azu.env") do |logs|
            Azu::Env.load_all(dir).should be_empty
            logs.empty
          end
          ENV["TZ"].should eq "Europe/Paris"
        end
      end
    end

    it "loads the new families with unsafe: true" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "TZ=UTC\nCFLAGS=-O2\n")
        with_env({"TZ" => nil, "CFLAGS" => nil}) do
          Azu::Env.load(path, unsafe: true).sort!.should eq ["CFLAGS", "TZ"]
          ENV["TZ"].should eq "UTC"
        end
      end
    end

    it "refuses a file larger than 1 MB" do
      with_dir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=" + "x" * 1_048_577)
        expect_raises(Azu::Env::ParseError, /larger than 1 MB/) { Azu::Env.load(path) }
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

    it "treats a blank process CRYSTAL_ENV as unset when choosing the file and when applying" do
      with_dir do |dir|
        File.write(File.join(dir, ".env"), "CRYSTAL_ENV=staging\nAZU_ENV_SPEC_P=base\n")
        File.write(File.join(dir, ".env.staging"), "AZU_ENV_SPEC_P=staging\n")
        with_env({"CRYSTAL_ENV" => "", "AZU_ENV_SPEC_P" => nil}) do
          Azu::Env.load_all(dir)
          ENV["CRYSTAL_ENV"].should eq "staging"
          ENV["AZU_ENV_SPEC_P"].should eq "staging"
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

    it "warns once per name about the per-process fallback" do
      with_env({"AZU_ENV_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "development"}) do
        Log.capture("azu.env") do |logs|
          Azu::Env.secret("AZU_ENV_SPEC_SECRET")
          Azu::Env.secret("AZU_ENV_SPEC_SECRET")
          logs.check(:warn, /AZU_ENV_SPEC_SECRET is not set: using a random value/)
          logs.empty
        end
      end
    end

    it "raises in the environments listed as strict" do
      with_env({"AZU_ENV_SPEC_SECRET" => nil, "CRYSTAL_ENV" => "staging"}) do
        Azu::Env.secret("AZU_ENV_SPEC_SECRET").should_not be_empty
        Azu::Env.strict_environments = ["production", "Staging"]
        begin
          expect_raises(Azu::Env::MissingError, /AZU_ENV_SPEC_SECRET is not set/) { Azu::Env.secret("AZU_ENV_SPEC_SECRET") }
        ensure
          Azu::Env.strict_environments = nil
        end
      end
    end

    it "reads strict environments from AZU_STRICT_ENVS" do
      Azu::Env.strict_environments = nil
      with_env({"CRYSTAL_ENV" => "staging", "AZU_STRICT_ENVS" => "production, staging"}) do
        Azu::Env.strict_environments.should eq ["production", "staging"]
        Azu::Env.strict?.should be_true
      end
      with_env({"CRYSTAL_ENV" => "staging", "AZU_STRICT_ENVS" => nil}) { Azu::Env.strict?.should be_false }
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

    it "filters more secret-looking names and URL passwords containing a slash" do
      %w[STRIPE_APIKEY API_KEY SENTRY_DSN PASSWORD_SALT JWT_SIGNING AUTH_HEADER BASIC_AUTH].each do |name|
        Azu::Env.redact(name, "abc").should eq "[FILTERED]"
      end
      Azu::Env.redact("DATABASE_URL", "postgres://app:pa/ss@db/app").should eq "postgres://app:[FILTERED]@db/app"
      Azu::Env.redact("REDIS_URL", "redis://localhost:6379/0").should eq "redis://localhost:6379/0"
    end

    it "filters passwords, sessions, signatures, one-time codes and hyphenated header names" do
      %w[MYSQL_PWD DB_PASS APP_JWT SESSION_ID SID X-Session-Id X-Api-Key-Id X-Auth-Token OTP_CODE CARD_NUMBER CVV SSN X-Signature CONNECTION_STRING AZURE_STORAGE_CONNECTION_STRING PIN].each do |name|
        Azu::Env.redact(name, "abc").should eq "[FILTERED]"
      end
      %w[PORT HOST PINNED SPINNER PASSENGER BYPASS CARDINAL CRYSTAL_ENV Accept User-Agent SESSIONS_DIR XDG_SESSION_TYPE PWD].each do |name|
        Azu::Env.redact(name, "abc").should eq "abc"
      end
    end

    it "hides URL passwords and credential query parameters anywhere in a value" do
      Azu::Env.redact_url("https://shop.example/cb?token=hunter2&page=2").should eq "https://shop.example/cb?token=[FILTERED]&page=2"
      Azu::Env.redact_url("see postgres://app:hunter2@db/app and redis://:pw@cache/0").should eq "see postgres://app:[FILTERED]@db/app and redis://:[FILTERED]@cache/0"
      Azu::Env.redact("Referer", "https://a.example/x?next=/home&password=hunter2").should eq "https://a.example/x?next=/home&password=[FILTERED]"
      Azu::Env.redact_url("/search?q=azu&page=2").should eq "/search?q=azu&page=2"
    end

    it "keeps URLs whose path or query merely contains an @ or a port" do
      ["http://localhost:3000/users/@alice", "https://x.example/y?email=a@b.c", "http://h:8080/a?e=a@b.c", "see http://localhost:3000/@me"].each do |text|
        Azu::Env.redact_url(text).should eq text
      end
      Azu::Env.redact_url("http://user:8080@h/x").should eq "http://user:[FILTERED]@h/x"
    end

    it "redacts MYSQL_PWD and SESSION_ID but not the working directory" do
      Azu::Env.redact("MYSQL_PWD", "abc").should eq "[FILTERED]"
      Azu::Env.redact("SESSION_ID", "abc").should eq "[FILTERED]"
      Azu::Env.redact("PWD", "/home/app").should eq "/home/app"
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
