require "spec"
require "file_utils"
require "../../scripts/docs_check"

private def with_page(content : String, &)
  path = File.tempname("docs-check", ".md")
  File.write(path, content)
  begin
    yield path
  ensure
    File.delete(path)
  end
end

private PAGE = <<-MD
  # Page

  <!-- prelude -->
  ```crystal
  struct Shared
    def value : Int32
      1
    end
  end
  ```

  <!-- skip -->
  ```crystal
  fragment
  ```

  ```crystal
  def twice : Int32
    Shared.new.value * 2
  end
  ```

  <!-- prelude -->
  ```crystal
  struct More
  end
  ```

  ```crystal
  More.new
  ```
  MD

describe DocsCheck do
  describe ".snippets" do
    it "drops skipped blocks and gives every later block the page's preludes so far" do
      with_page(PAGE) do |path|
        snippets = DocsCheck.snippets(path)

        snippets.map(&.line).should eq [5, 18, 25, 30]
        snippets[0].prelude.should eq ""
        snippets[1].prelude.should contain "struct Shared"
        snippets[1].prelude.should_not contain "struct More"
        snippets[2].prelude.should contain "struct Shared"
        snippets[3].prelude.should contain "struct More"
        snippets.none?(&.source.includes?("fragment")).should be_true
      end
    end
  end

  describe ".mark_before" do
    it "finds a marker above GitBook block tags" do
      lines = ["<!-- skip -->", %({% code title="src/app.cr" %}), "```crystal", "fragment", "```"]

      DocsCheck.mark_before(lines, 2).should eq "<!-- skip -->"
    end

    it "finds no marker above a plain fence" do
      DocsCheck.mark_before(["Text.", "```crystal"], 1).should eq "Text."
      DocsCheck.mark_before(["```crystal"], 0).should eq ""
    end
  end

  describe ".program" do
    it "puts the require first, then the prelude, then the block" do
      snippet = DocsCheck::Snippet.new("page.md", 1, "Shared.new\n", "struct Shared\nend\n")

      DocsCheck.program(snippet).should start_with %(require "azu"\nstruct Shared\nend\nShared.new\n)
    end

    it "does not add a require when the code that comes first has one" do
      snippet = DocsCheck::Snippet.new("page.md", 1, "X.new\n", %(require "azu"\nstruct X\nend\n))

      DocsCheck.program(snippet).scan(%(require "azu")).size.should eq 1
    end

    it "body-checks only the methods of the block, not those of the prelude" do
      prelude = "struct Shared\n  def value : Int32\n    1\n  end\nend\n"
      snippet = DocsCheck::Snippet.new("page.md", 1, "def twice : Int32\n  2\nend\n", prelude)

      # require on line 1, the prelude on 2-6, the block's `def` on 7
      DocsCheck.program(snippet).should contain "def_lines = [7]"
    end
  end

  describe ".body_check" do
    it "is empty when the block defines no method" do
      DocsCheck.body_check("puts 1\n").should eq ""
    end
  end
end
