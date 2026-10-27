require "uri"

module Azu
  class ExceptionPage
    # Lines of a source file around one line: `start` is the number of the first line, `line` the one to highlight.
    record Excerpt, start : Int32, line : Int32, lines : Array(String)

    # One line of a backtrace (`src/app.cr:12:5 in 'call'`), with where it comes from: the app, a shard, Azu or the
    # Crystal standard library. Only app frames are read from disk, so a frame never shows a file outside the
    # project.
    struct Frame
      enum Kind
        App
        Azu
        Shard
        Crystal

        def label : String
          case self
          in .app?     then "Your application"
          in .azu?     then "Azu"
          in .shard?   then "Shards"
          in .crystal? then "Crystal"
          end
        end
      end

      EXCERPT_RADIUS    =         6
      EXCERPT_MAX_BYTES = 1_000_000
      EXCERPT_MAX_WIDTH =       400

      # `AZU_EDITOR` names an editor, or is a template with `%{file}`, `%{line}` and `%{column}`.
      EDITORS = {
        "vscode"   => "vscode://file/%{file}:%{line}:%{column}",
        "cursor"   => "cursor://file/%{file}:%{line}:%{column}",
        "windsurf" => "windsurf://file/%{file}:%{line}:%{column}",
        "zed"      => "zed://file/%{file}:%{line}:%{column}",
        "idea"     => "idea://open?file=%{file}&line=%{line}",
        "rubymine" => "x-mine://open?file=%{file}&line=%{line}",
        "sublime"  => "subl://open?url=file://%{file}&line=%{line}",
        "textmate" => "txmt://open?url=file://%{file}&line=%{line}",
        "emacs"    => "emacs://open?url=file://%{file}&line=%{line}",
        "nova"     => "nova://open?path=%{file}&line=%{line}",
      }

      # Azu's own sources: this file is `src/azu/exception_page/frame.cr`.
      AZU_SOURCE = File.expand_path("..", __DIR__)

      private LOCATED   = /\A(?<file>.+?):(?<line>\d+)(?::(?<column>\d+))? in '(?<method>.*)'/
      private SHARD_DIR = %r{(?:\A|/)lib/(?<shard>[^/]+)/}

      getter raw : String
      # The file as shown: relative to the project root when it is inside it.
      getter file : String
      # The absolute path, nil when the backtrace line names no file.
      getter path : String?
      getter line : Int32?
      getter column : Int32?
      getter method : String?
      getter kind : Kind
      getter shard : String?

      def initialize(@raw, @file, @path, @line, @column, @method, @kind, @shard)
      end

      def self.parse(text : String, root : String = Dir.current) : Frame
        match = LOCATED.match(text)
        return new(text, text, nil, nil, nil, nil, Kind::Crystal, nil) unless match

        file = match["file"]
        path = File.expand_path(file, root)
        shard = SHARD_DIR.match(file).try(&.["shard"])
        kind = classify(path, root, shard)
        shown = path.starts_with?("#{root}/") ? path[root.size + 1..] : file
        new(text, shown, path, match["line"].to_i, match["column"]?.try(&.to_i), match["method"], kind, kind.shard? ? shard : nil)
      end

      def self.parse_all(backtrace : Array(String)?, root : String = Dir.current) : Array(Frame)
        (backtrace || [] of String).map { |text| parse(text, root) }
      end

      private def self.classify(path : String, root : String, shard : String?) : Kind
        return Kind::Azu if shard == "azu" || path.starts_with?("#{AZU_SOURCE}/")
        return Kind::Shard if shard
        return Kind::App if path.starts_with?("#{root}/") && !standard_library?(path, root)
        Kind::Crystal
      end

      @@stdlib_dirs = {} of String => Bool
      @@stdlib_mutex = Mutex.new

      # A Crystal installed inside the project (a vendored or tool-managed compiler) is not the app: its source
      # directory is the one holding `prelude.cr`.
      private def self.standard_library?(path : String, root : String) : Bool
        dir = File.dirname(path)
        @@stdlib_mutex.synchronize do
          @@stdlib_dirs.fetch(dir) do
            found = false
            current = dir
            while current.starts_with?("#{root}/") && !found
              found = File.file?(File.join(current, "prelude.cr")) && File.file?(File.join(current, "kernel.cr"))
              current = File.dirname(current)
            end
            @@stdlib_dirs.clear if @@stdlib_dirs.size > 1_000
            @@stdlib_dirs[dir] = found
          end
        end
      end

      def app? : Bool
        kind.app?
      end

      # `file:line`, or the raw backtrace text for a frame without a location.
      def location : String
        line ? "#{file}:#{line}" : raw
      end

      # A link that opens the frame in the editor `AZU_EDITOR` names, nil when it is unset or the frame has no file.
      def editor_url(editor : String? = ENV["AZU_EDITOR"]?) : String?
        return if editor.nil? || editor.empty?
        return unless (path = @path) && (line = @line)

        template = EDITORS[editor.downcase]? || (editor.includes?("%{file}") ? editor : nil)
        template.try do |chosen|
          chosen.gsub("%{file}", URI.encode_path(path)).gsub("%{line}", line.to_s).gsub("%{column}", (column || 1).to_s)
        end
      end

      # The source around the frame's line, read only for app frames inside `root` (nil otherwise, or when the file
      # cannot be read).
      def excerpt(root : String = Dir.current, radius : Int32 = EXCERPT_RADIUS) : Excerpt?
        return unless app? && (path = @path) && (line = @line) && path.starts_with?("#{root}/")
        return unless File.file?(path) && File.size(path) <= EXCERPT_MAX_BYTES

        first = Math.max(line - radius, 1)
        lines = read_lines(path, first, line + radius)
        lines.empty? ? nil : Excerpt.new(first, line, lines)
      rescue File::Error | IO::Error | ArgumentError
        nil
      end

      private def read_lines(path : String, first : Int32, last : Int32) : Array(String)
        lines = [] of String
        File.open(path) do |io|
          io.each_line.with_index(1) do |text, number|
            break if number > last
            lines << text[0, EXCERPT_MAX_WIDTH] if number >= first
          end
        end
        lines
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "file", file
          json.field "line", line
          json.field "column", column
          json.field "method", method
          json.field "kind", kind.to_s.downcase
          json.field "shard", shard if shard
          editor_url.try { |url| json.field "editor_url", url }
        end
      end
    end
  end
end
