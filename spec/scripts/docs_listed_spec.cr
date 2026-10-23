require "spec"
require "file_utils"
require "../../scripts/docs_listed"

private def with_tree(&)
  root = File.tempname("docs-listed")
  Dir.mkdir_p(File.join(root, "docs", "plans"))
  Dir.mkdir_p(File.join(root, "docs", "guides"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private CRYSTAL_PAGE = "# Page\n\n```crystal\nputs 1\n```\n"
private TEXT_PAGE    = "# Page\n\n```text\nputs 1\n```\n"

describe DocsListed do
  it "reports a page with a crystal block that is not listed" do
    with_tree do |root|
      File.write(File.join(root, "docs", ".checked"), "# comment\nREADME.md\n")
      File.write(File.join(root, "README.md"), CRYSTAL_PAGE)
      File.write(File.join(root, "docs", "guides", "new.md"), CRYSTAL_PAGE)

      DocsListed.missing(root).should eq ["docs/guides/new.md"]
    end
  end

  it "ignores listed pages, pages without crystal blocks and docs/plans" do
    with_tree do |root|
      File.write(File.join(root, "docs", ".checked"), "docs/guides/old.md\n")
      File.write(File.join(root, "docs", "guides", "old.md"), CRYSTAL_PAGE)
      File.write(File.join(root, "docs", "guides", "text.md"), TEXT_PAGE)
      File.write(File.join(root, "docs", "plans", "idea.md"), CRYSTAL_PAGE)

      DocsListed.missing(root).should be_empty
    end
  end

  it "holds for this repository" do
    DocsListed.missing(File.expand_path("../..", __DIR__)).should be_empty
  end
end
