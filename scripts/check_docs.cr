require "./docs_check"

# Runs DocsCheck (scripts/docs_check.cr) over the given Markdown files; see that file for what is checked.
#
#     crystal run scripts/check_docs.cr -- README.md docs/tutorials/getting-started.md
#     crystal run scripts/check_docs.cr -- --shard 2/4 $(grep -v '^#' docs/.checked)

args = ARGV.to_a
if position = args.index("--shard")
  spec = args[position + 1]? || abort("--shard expects i/n")
  args.delete_at(position, 2)
  index, count = DocsCheck.parse_shard(spec)
  args = DocsCheck.shard(args, index, count)
end
exit DocsCheck.run(args)
