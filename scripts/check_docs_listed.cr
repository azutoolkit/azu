require "./docs_listed"

# Fails when a Markdown file with a ```crystal block is not listed in docs/.checked, so a new page cannot
# slip past scripts/check_docs.cr. List the file (after making its blocks compile), or relabel blocks that
# are not meant to compile with another language such as `text`.
#
#     crystal run scripts/check_docs_listed.cr
missing = DocsListed.missing(ARGV[0]? || Dir.current)
if missing.empty?
  puts "Every Markdown file with crystal blocks is listed in docs/.checked"
else
  STDERR.puts "These files have ```crystal blocks but are not listed in docs/.checked:"
  missing.each { |path| STDERR.puts "  #{path}" }
  STDERR.puts "Make their blocks compile (scripts/check_docs.cr) and add them to docs/.checked."
  exit 1
end
