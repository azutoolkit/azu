require "./doc_links"

# Runs the DocLinks checks (scripts/doc_links.cr) over README.md and docs/; exits 1 when any fails.
#
#     crystal run scripts/check_doc_links.cr

pages = Dir.glob("docs/**/*.md").sort
files = ["README.md"] + pages
problems = DocLinks.check(files) + DocLinks.sidebar("docs/SUMMARY.md", pages - ["docs/SUMMARY.md"])
orphans = DocLinks.orphans("docs/README.md", pages)

problems.each { |problem| STDERR.puts problem }
orphans.each { |page| STDERR.puts "#{page} is not linked from docs/README.md" }
puts "#{files.size} files checked, #{problems.size} problems, #{orphans.size} unlinked pages"
exit(problems.empty? && orphans.empty? ? 0 : 1)
