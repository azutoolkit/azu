# Checks of README.md and docs/**/*.md (run by scripts/check_doc_links.cr):
#
# - every relative link resolves to a file or directory and, when it has a #fragment, to a heading of the target
#   page with that GitHub-style anchor; a link to this repository on GitHub is checked the same way against the
#   local file;
# - a page under docs/ does not link outside docs/ with a relative link (GitBook publishes docs/ only);
# - docs/README.md links every page under docs/;
# - the GitBook sidebar, docs/SUMMARY.md, lists every page once, one link per item, labelled with the page title.
#
# Links inside fenced code blocks and other external links (http, https, mailto) are not checked.
module DocLinks
  LINK        = /\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  HREF        = /\bhref="([^"]+)"/
  CONTENT_REF = /\{%\s*content-ref\s+url="([^"]+)"\s*%\}/
  HEADING     = /^(\#{1,6})\s+(.*?)\s*#*\s*$/
  ITEM        = /^\s*[*-]\s+(.*?)\s*$/
  LABEL       = /\A\[([^\]]*)\]\(([^)\s]+)\)\z/
  REPO        = "https://github.com/azutoolkit/azu"

  # The local path (with any #fragment) that a link to this repository on GitHub names, or nil for any other
  # target. Pages under docs/ link files outside it this way, because GitBook publishes docs/ only.
  def self.repo_path(target : String) : String?
    if target.starts_with?("#{REPO}/blob/master/")
      target.lchop("#{REPO}/blob/master/")
    elsif target == REPO || target.starts_with?("#{REPO}#")
      "README.md" + target.lchop(REPO)
    end
  end

  # GitHub's anchor for a heading: lowercase, markup and punctuation dropped, spaces turned into hyphens.
  def self.slug(heading : String) : String
    text = heading.gsub(/\[([^\]]*)\]\([^)]*\)/, "\\1").downcase
    text.gsub(/[^\p{L}\p{N}\s\-_]/, "").gsub(/\s/, "-")
  end

  # A code fence opens with three or more backticks or tildes and closes with at least as many of the same
  # character, so a four-backtick fence can contain a three-backtick one.
  class Fences
    @marker : String? = nil

    # True when `line` is inside a fence or is a fence line itself.
    def skip?(line : String) : Bool
      stripped = line.lstrip
      if marker = @marker
        @marker = nil if stripped.starts_with?(marker) && stripped.chars.all? { |char| char == marker[0] || char.whitespace? }
        return true
      end
      if match = /\A(`{3,}|~{3,})/.match(stripped)
        @marker = match[1]
        return true
      end
      false
    end
  end

  # The link targets on *line*: Markdown links, HTML `href`s (GitBook cards and buttons) and GitBook page links
  # (`{% content-ref url="…" %}`). Inline code is left out: a link shown as code is an example, not a link.
  def self.each_target(line : String, &)
    line = line.gsub(/`[^`]*`/, "")
    line.scan(LINK) { |match| yield match[1] }
    line.scan(HREF) { |match| yield match[1] }
    line.scan(CONTENT_REF) { |match| yield match[1] }
  end

  def self.each_line_outside_fences(path : String, &)
    fences = Fences.new
    File.each_line(path) do |line|
      yield line unless fences.skip?(line)
    end
  end

  def self.anchors(path : String) : Set(String)
    seen = Hash(String, Int32).new(0)
    found = Set(String).new
    each_line_outside_fences(path) do |line|
      next unless match = HEADING.match(line)
      base = slug(match[2])
      count = seen[base]
      seen[base] += 1
      found << (count == 0 ? base : "#{base}-#{count}")
    end
    found
  end

  def self.check(files : Array(String)) : Array(String)
    cache = Hash(String, Set(String)).new
    problems = [] of String
    files.each do |file|
      number = 0
      fences = Fences.new
      File.each_line(file) do |line|
        number += 1
        next if fences.skip?(line)
        each_target(line) do |target|
          if local = repo_path(target)
            path_part, _, fragment = local.partition('#')
            resolved = path_part
          else
            next if target.starts_with?("http://") || target.starts_with?("https://") || target.starts_with?("mailto:")
            path_part, _, fragment = target.partition('#')
            resolved = path_part.empty? ? file : File.expand_path(path_part, File.dirname(file)).sub("#{Dir.current}/", "")
            if file.starts_with?("docs/") && !resolved.starts_with?("docs/")
              problems << "#{file}:#{number}: #{target} leaves docs/, which is all GitBook publishes; link #{REPO}/blob/master/#{resolved} instead"
              next
            end
          end
          unless File.exists?(resolved)
            problems << "#{file}:#{number}: #{target} does not exist"
            next
          end
          next if fragment.empty? || !resolved.ends_with?(".md")
          unless (cache[resolved] ||= anchors(resolved)).includes?(fragment)
            problems << "#{file}:#{number}: #{target} has no heading with the anchor ##{fragment}"
          end
        end
      end
    end
    problems
  end

  def self.orphans(index : String, pages : Array(String)) : Array(String)
    linked = Set(String).new
    each_line_outside_fences(index) do |line|
      each_target(line) do |target|
        path_part = target.partition('#')[0]
        next if path_part.empty? || path_part.includes?("://")
        linked << File.expand_path(path_part, File.dirname(index)).sub("#{Dir.current}/", "")
      end
    end
    pages.reject { |page| linked.includes?(page) || page == index || page.ends_with?("SUMMARY.md") }
  end

  # The text of the first `# ` heading of *path*, outside code fences.
  def self.title(path : String) : String?
    each_line_outside_fences(path) do |line|
      return line.lchop("# ").strip if line.starts_with?("# ")
    end
    nil
  end

  # Checks the GitBook sidebar *summary* against *pages*: every item is exactly one link to a page under
  # docs/, every page is listed exactly once, and an item's label is the title of its page (the landing page,
  # *index*, keeps a short label).
  def self.sidebar(summary : String, pages : Array(String), index : String = "docs/README.md") : Array(String)
    problems = [] of String
    listed = Hash(String, Int32).new(0)
    number = 0
    fences = Fences.new
    File.each_line(summary) do |line|
      number += 1
      next if fences.skip?(line)
      next unless item = ITEM.match(line)
      unless link = LABEL.match(item[1])
        problems << "#{summary}:#{number}: a sidebar item is one link and nothing else: #{item[1]}"
        next
      end
      label, target = link[1], link[2]
      page = File.expand_path(target, File.dirname(summary)).sub("#{Dir.current}/", "")
      unless page.starts_with?("docs/") && File.file?(page)
        problems << "#{summary}:#{number}: #{target} is not a page under docs/"
        next
      end
      listed[page] += 1
      title = title(page)
      if page != index && title != label
        problems << "#{summary}:#{number}: the label \"#{label}\" differs from the title of #{page} (\"#{title}\")"
      end
    end
    pages.each do |page|
      count = listed[page]
      problems << "#{page} is not in #{summary}" if count == 0
      problems << "#{page} is in #{summary} #{count} times" if count > 1
    end
    problems
  end
end
