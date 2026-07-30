defmodule EftBuddy.Wiki.MarkupTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.Markup

  describe "clean_text/1" do
    test "strips templates, tags, links and emphasis and collapses whitespace" do
      assert Markup.clean_text("{{tpl|x}}'''Bold''' and [[Page|label]]   text") ==
               "Bold and label text"
    end

    test "non-binary input becomes an empty string" do
      assert Markup.clean_text(nil) == ""
      assert Markup.clean_text(123) == ""
    end
  end

  describe "normalize_inline_wiki_markup/1" do
    test "resolves piped and plain links" do
      assert Markup.normalize_inline_wiki_markup("[[A|B]] and [[C]]") == "B and C"
    end

    test "strips bold/italic even when the text contains an apostrophe" do
      # Regression: the old `'''(...)'''` regex left markers when the
      # emphasised text held an apostrophe (e.g. "didn't").
      assert Markup.normalize_inline_wiki_markup("'''didn't escape'''") == "didn't escape"
      assert Markup.normalize_inline_wiki_markup("''italic''") == "italic"
    end
  end

  describe "strip_inline_file_refs/1" do
    test "removes inline File:/Image: references including nested link captions" do
      assert Markup.strip_inline_file_refs("see [[File:Foo.png|thumb|[[Bar]] cap]] now") ==
               "see now"
    end
  end

  describe "strip_html_comments/1 and strip_nowiki/1" do
    test "removes comments and nowiki blocks" do
      assert Markup.strip_html_comments("a<!-- hidden -->b") == "ab"
      assert Markup.strip_nowiki("a<nowiki>raw</nowiki>b") == "ab"
    end
  end

  describe "metadata_paragraph?/1" do
    test "flags category links and interwiki prefixes, not real prose" do
      assert Markup.metadata_paragraph?("Category:Quests")
      assert Markup.metadata_paragraph?("cs:Zlatý lup")
      refute Markup.metadata_paragraph?("A normal sentence.")
    end

    test "flags uppercase / collapsed interlanguage blocks" do
      # Regression: the bottom-of-page interlanguage links collapse into one
      # paragraph beginning with an uppercase code (`FR:`), which the old
      # lowercase-only regex let through into the guide.
      assert Markup.metadata_paragraph?("FR:Swag - Partie 1 cs:Vystrojení se ru:Обновка")
      assert Markup.metadata_paragraph?("RU:Обновка. Часть 1")
    end
  end

  describe "scan_wikilink/2" do
    test "returns the inner text and the position past the closing ]]" do
      line = "x[[Foo|Bar]]y"
      # opening [[ starts at byte 1, inner begins at byte 3
      assert {:ok, "Foo|Bar", after_pos} = Markup.scan_wikilink(line, 3)
      assert binary_part(line, after_pos, 1) == "y"
    end

    test "honours nested [[ ... ]]" do
      line = "[[File:A.png|[[Bar]] cap]]"
      assert {:ok, inner, after_pos} = Markup.scan_wikilink(line, 2)
      assert inner == "File:A.png|[[Bar]] cap"
      assert after_pos == byte_size(line)
    end

    test "returns :error on an unterminated link" do
      assert Markup.scan_wikilink("[[Foo", 2) == :error
    end
  end

  describe "split_pipes_depth_aware/1" do
    test "splits on top-level pipes only, ignoring pipes inside nested links" do
      assert Markup.split_pipes_depth_aware("File:A.png|thumb|[[Bar|baz]] cap") ==
               ["File:A.png", "thumb", "[[Bar|baz]] cap"]
    end
  end
end
