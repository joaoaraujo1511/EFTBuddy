defmodule EftBuddy.Chapters.SectionParserTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Chapters.SectionParser

  # Build a section map the way the manifest stores it (string keys).
  defp section(wikitext, opts \\ []) do
    %{
      "slug" => Keyword.get(opts, :slug, "guide"),
      "level" => Keyword.get(opts, :level, 2),
      "index" => Keyword.get(opts, :index, "4"),
      "wikitext" => wikitext,
      "files" => Keyword.get(opts, :files, [])
    }
  end

  defp file(name, url) do
    %{"wiki_filename" => name, "url" => url, "banner" => false}
  end

  describe "parse/1 basics" do
    test "the lead/infobox section is dropped" do
      assert SectionParser.parse(%{"slug" => "lead", "wikitext" => "==X==\nstuff"}) == []
    end

    test "non-binary / malformed input yields no blocks" do
      assert SectionParser.parse(%{"slug" => "x"}) == []
      assert SectionParser.parse(:nope) == []
    end

    test "the section's own heading is not emitted, prose is" do
      blocks = SectionParser.parse(section("==Guide==\nFind the camp on Lighthouse."))
      assert blocks == [%{kind: :prose, text: "Find the camp on Lighthouse."}]
    end
  end

  describe "lists" do
    test "bullet lists keep nesting depth" do
      blocks = SectionParser.parse(section("==H==\n* one\n** two\n* three"))

      assert [%{kind: :list, ordered: false, items: items}] = blocks

      assert items == [
               %{level: 1, text: "one"},
               %{level: 2, text: "two"},
               %{level: 1, text: "three"}
             ]
    end

    test "numbered lists are marked ordered" do
      assert [%{kind: :list, ordered: true}] = SectionParser.parse(section("==H==\n# step one"))
    end
  end

  describe "prose cleaning" do
    test "{{quote}} templates are unwrapped into prose" do
      blocks = SectionParser.parse(section("==H==\n{{quote|For the sake of all of us.}}"))
      assert [%{kind: :prose, text: "For the sake of all of us."}] = blocks
    end

    test "bold markup containing an apostrophe is still stripped" do
      blocks = SectionParser.parse(section("==H==\n'''didn't escape''' from yourself"))
      assert [%{kind: :prose, text: text}] = blocks
      refute text =~ "'''"
      assert text == "didn't escape from yourself"
    end
  end

  describe "sub-section de-duplication" do
    test "a page-own section stops at its first sub-heading" do
      # MediaWiki returns the parent's wikitext including child sections;
      # those children are dumped separately, so we must stop.
      blocks =
        SectionParser.parse(
          section("==Guide==\nIntro line.\n===Step One===\nChild content.", index: "4")
        )

      assert blocks == [%{kind: :prose, text: "Intro line."}]
    end

    test "a transcluded (tmpl:) section renders its sub-headings in full" do
      blocks =
        SectionParser.parse(
          section("===Step One===\nKept content.",
            index: "tmpl:Template:The_Ticket_Section_Savior_Guide",
            level: 2
          )
        )

      assert [%{kind: :heading, text: "Step One"}, %{kind: :prose, text: "Kept content."}] =
               blocks
    end
  end

  describe "galleries" do
    test "<gallery> entries resolve to dumped files with captions" do
      files = [file("Spawn1.png", "https://cdn/spawn1.png")]

      blocks =
        SectionParser.parse(
          section("==H==\n<gallery>\nFile:Spawn1.png|On the crate.\n</gallery>", files: files)
        )

      assert [%{kind: :gallery, images: [image]}] = blocks
      assert image.caption == "On the crate."
      assert image.file["url"] == "https://cdn/spawn1.png"
    end

    test "gallery images with no matching dumped file are dropped" do
      blocks =
        SectionParser.parse(
          section("==H==\n<gallery>\nFile:Missing.png|x\n</gallery>", files: [])
        )

      assert blocks == []
    end
  end

  describe "Related Quest Items tables" do
    @table """
    ==Guide==
    {|class="wikitable"
    ! colspan="5" |Related Quest Items
    |-
    !Icon
    !Item name
    !Amount
    !Requirement
    !'''[[Found in raid|Find in raid]]'''
    |-
    ![[File:Foo icon.png|link=Foo]]
    |[[Foo]]
    |2
    |Required
    !<font color="red">Yes</font>
    |-
    ![[File:Bar icon.png|link=Bar Page]]
    |[[Bar Page|Bar]]
    |1
    |Optional
    !N/A
    |}
    """

    test "parses each row into a linkable item with amount/requirement/FiR (no wiki icon)" do
      blocks = SectionParser.parse(section(@table))
      assert [%{kind: :items, items: [foo, bar]}] = blocks

      # No icon field — item images come from the API at render time.
      assert foo == %{
               name: "Foo",
               page: "Foo",
               amount: "2",
               requirement: "Required",
               found_in_raid: true
             }

      # [[Page|Display]] keeps Page for the link target, Display for the label.
      assert bar.name == "Bar"
      assert bar.page == "Bar Page"
      assert bar.requirement == "Optional"
      assert bar.found_in_raid == nil
    end

    test "decorative (non-item) tables are dropped, not rendered" do
      decorative = """
      ==H==
      {| style="border:1px solid #718e63;"
      | style="text-align:center" | Savior ending
      |}
      """

      assert SectionParser.parse(section(decorative)) == []
    end
  end
end
