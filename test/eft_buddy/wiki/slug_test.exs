defmodule EftBuddy.Wiki.SlugTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.Slug

  describe "normalize_name/1" do
    test "lowercases and dash-joins" do
      assert Slug.normalize_name("Golden Swag") == "golden-swag"
      assert Slug.normalize_name("  Hot Delivery  ") == "hot-delivery"
    end

    test "collapses punctuation runs and trims dashes" do
      assert Slug.normalize_name("Quest (Part 1)!") == "quest-part-1"
    end

    test "folds accents to ASCII so the slug matches tarkov.dev normalizedName" do
      # Regression: the old `[^a-z0-9]+` slug dropped accents entirely,
      # producing "caf" while the API transliterates to "cafe" — which
      # falsely flagged the quest WIP and broke cross-linking.
      assert Slug.normalize_name("Café") == "cafe"
      assert Slug.normalize_name("Grenadier Über") == "grenadier-uber"
    end
  end

  describe "slugify/1 and truncate_slug/2" do
    test "lowercases, underscore-joins and trims" do
      assert Slug.slugify("First Spawn!") == "first_spawn"
    end

    test "truncate prefers an underscore boundary past the halfway point" do
      assert Slug.truncate_slug("aaaa_bbbb_cccc", 10) == "aaaa_bbbb"
    end

    test "truncate keeps a hard cut when no late underscore exists" do
      assert Slug.truncate_slug("aaaaaaaa_bb", 5) == "aaaaa"
    end

    test "short slugs are returned unchanged" do
      assert Slug.truncate_slug("abc", 10) == "abc"
    end
  end
end
