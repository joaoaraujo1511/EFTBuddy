defmodule EftBuddy.Wiki.UrlTest do
  @moduledoc """
  Wiki source links are the "URI to the material" CC BY-NC-SA attribution
  requires. They were built by replacing spaces and nothing else, so five live
  quest titles containing `?` linked to the wrong page (audit M20).
  """
  use ExUnit.Case, async: true

  doctest EftBuddy.Wiki.Url

  alias EftBuddy.Wiki.{Projection, Url}

  @base "https://escapefromtarkov.fandom.com/wiki/"

  describe "page/1" do
    test "escapes what would otherwise be URL syntax" do
      assert Url.page("Are you going to eat that?") == @base <> "Are_you_going_to_eat_that%3F"
      assert Url.page("#FireKlean") == @base <> "%23FireKlean"
      assert Url.page("Salt & Pepper") == @base <> "Salt_%26_Pepper"
      assert Url.page("100% Done") == @base <> "100%25_Done"
      assert Url.page("A+B") == @base <> "A%2BB"
    end

    test "keeps what MediaWiki keeps, and encodes non-ASCII as UTF-8" do
      assert Url.page("Gunsmith - Part 1") == @base <> "Gunsmith_-_Part_1"
      assert Url.page("Special:ListFiles/Some User") == @base <> "Special:ListFiles/Some_User"
      assert Url.page("Shturman's Stash (Woods)") == @base <> "Shturman%27s_Stash_(Woods)"
      assert Url.page("Ёлка") == @base <> "%D0%81%D0%BB%D0%BA%D0%B0"
    end
  end

  describe "normalize/1" do
    test "repairs a link stored before encoding, and leaves an encoded one alone" do
      raw = @base <> "Are_you_going_to_eat_that?"
      fixed = Url.normalize(raw)

      assert fixed == @base <> "Are_you_going_to_eat_that%3F"
      assert Url.normalize(fixed) == fixed
    end

    test "keeps a literal percent sign that was never an escape" do
      assert Url.normalize(@base <> "100%_Done") == @base <> "100%25_Done"
    end

    test "passes other links and nil through" do
      assert Url.normalize("https://example.com/a?b") == "https://example.com/a?b"
      assert Url.normalize(nil) == nil
    end
  end

  test "a quest projection serves the repaired link, without a rescrape" do
    # Unchanged pages are skipped by the quest scrape, so a link stored broken
    # stays stored broken; the projection is what the UI reads.
    manifest = %{
      "normalized_name" => "eat-that",
      "wiki_link" => @base <> "Are_you_going_to_eat_that?"
    }

    assert Projection.project(manifest).wiki_link == @base <> "Are_you_going_to_eat_that%3F"
  end

  test "contributor profile links are encoded" do
    assert EftBuddy.Credits.profile_url("Some User?") == @base <> "UserProfile:Some_User%3F"
  end
end
