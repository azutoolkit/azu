require "spec"
require "file_utils"
require "../../scripts/doc_links"

# Runs the block inside a fresh tree with README.md, docs/README.md and docs/guide.md ("# Guide").
private def in_tree(&)
  root = File.tempname("doc-links")
  Dir.mkdir_p(File.join(root, "docs"))
  File.write(File.join(root, "README.md"), "# Project\n\n## Get started\n")
  File.write(File.join(root, "docs", "README.md"), "# Overview of everything\n")
  File.write(File.join(root, "docs", "guide.md"), "# Guide\n\n## Steps\n")
  begin
    Dir.cd(root) { yield }
  ensure
    FileUtils.rm_rf(root)
  end
end

private def sidebar(items : String) : Array(String)
  File.write("docs/SUMMARY.md", "# Table of contents\n\n#{items}")
  DocLinks.sidebar("docs/SUMMARY.md", ["docs/README.md", "docs/guide.md"])
end

describe DocLinks do
  describe ".sidebar" do
    it "accepts one titled link per page" do
      in_tree do
        sidebar("* [Overview](README.md)\n\n## Guides\n\n* [Guide](guide.md)\n").should be_empty
      end
    end

    it "rejects an item with two links or with text after the link" do
      in_tree do
        problems = sidebar("* [Overview](README.md), [Guide](guide.md)\n* [Guide](guide.md): the guide\n")

        problems.count(&.includes?("one link and nothing else")).should eq 2
      end
    end

    it "rejects a label that is not the page title" do
      in_tree do
        sidebar("* [Overview](README.md)\n* [The guide](guide.md)\n").should eq [
          %(docs/SUMMARY.md:4: the label "The guide" differs from the title of docs/guide.md ("Guide")),
        ]
      end
    end

    it "reports a page that is missing, listed twice or outside docs/" do
      in_tree do
        problems = sidebar("* [Guide](guide.md)\n* [Guide](guide.md)\n* [Project](../README.md)\n")

        problems.should contain "docs/README.md is not in docs/SUMMARY.md"
        problems.should contain "docs/guide.md is in docs/SUMMARY.md 2 times"
        problems.should contain "docs/SUMMARY.md:5: ../README.md is not a page under docs/"
      end
    end
  end

  describe ".check" do
    it "rejects a relative link from docs/ to a file outside it" do
      in_tree do
        File.write("docs/guide.md", "# Guide\n\nSee [the project](../README.md).\n")

        DocLinks.check(["docs/guide.md"]).first.should contain "leaves docs/"
      end
    end

    it "checks links to this repository on GitHub against the local files and anchors" do
      in_tree do
        File.write("docs/guide.md", <<-MD)
          # Guide

          [ok](https://github.com/azutoolkit/azu#get-started)
          [bad anchor](https://github.com/azutoolkit/azu#nowhere)
          [missing](https://github.com/azutoolkit/azu/blob/master/benchmark/README.md)
          [other site](https://example.com/README.md#nowhere)
          MD

        DocLinks.check(["docs/guide.md"]).should eq [
          "docs/guide.md:4: https://github.com/azutoolkit/azu#nowhere has no heading with the anchor #nowhere",
          "docs/guide.md:5: https://github.com/azutoolkit/azu/blob/master/benchmark/README.md does not exist",
        ]
      end
    end

    it "lets the repository README link into docs/" do
      in_tree do
        File.write("README.md", "# Project\n\n[Guide](docs/guide.md#steps)\n")

        DocLinks.check(["README.md"]).should be_empty
      end
    end
  end
end
