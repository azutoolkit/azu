# Checks every relative link of README.md and docs/**/*.md: the target file or directory exists and, when the
# link has a #fragment, that a heading of the target page has that GitHub-style anchor. Also lists pages under
# docs/ that docs/README.md does not link to.
#
#     crystal run scripts/check_doc_links.cr
#
# Links inside fenced code blocks and external links (http, https, mailto) are not checked.
module DocLinks
  LINK    = /\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  HEADING = /^(\#{1,6})\s+(.*?)\s*#*\s*$/

  # GitHub's anchor for a heading: lowercase, markup and punctuation dropped, spaces turned into hyphens.
  def self.slug(heading : String) : String
    text = heading.gsub(/\[([^\]]*)\]\([^)]*\)/, "\\1").downcase
    text.gsub(/[^\p{L}\p{N}\s\-_]/, "").gsub(' ', '-')
  end

  def self.each_line_outside_fences(path : String, &)
    fenced = false
    File.each_line(path) do |line|
      if line.lstrip.starts_with?("```")
        fenced = !fenced
        next
      end
      yield line unless fenced
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
      fenced = false
      File.each_line(file) do |line|
        number += 1
        if line.lstrip.starts_with?("```")
          fenced = !fenced
          next
        end
        next if fenced
        line.scan(LINK) do |match|
          target = match[1]
          next if target.starts_with?("http://") || target.starts_with?("https://") || target.starts_with?("mailto:")
          path_part, _, fragment = target.partition('#')
          resolved = path_part.empty? ? file : File.expand_path(path_part, File.dirname(file)).sub("#{Dir.current}/", "")
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
      line.scan(LINK) do |match|
        path_part = match[1].partition('#')[0]
        next if path_part.empty? || path_part.includes?("://")
        linked << File.expand_path(path_part, File.dirname(index)).sub("#{Dir.current}/", "")
      end
    end
    pages.reject { |page| linked.includes?(page) || page == index || page.ends_with?("SUMMARY.md") }
  end
end

pages = Dir.glob("docs/**/*.md").sort
files = ["README.md"] + pages
problems = DocLinks.check(files)
orphans = DocLinks.orphans("docs/README.md", pages)

problems.each { |problem| STDERR.puts problem }
orphans.each { |page| STDERR.puts "#{page} is not linked from docs/README.md" }
puts "#{files.size} files checked, #{problems.size} broken links, #{orphans.size} unlinked pages"
exit(problems.empty? && orphans.empty? ? 0 : 1)
