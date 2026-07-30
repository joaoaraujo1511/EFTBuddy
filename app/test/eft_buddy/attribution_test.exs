defmodule EftBuddy.AttributionTest do
  @moduledoc """
  The credit strings themselves.

  These are ShareAlike sources, where attribution is a condition of the licence
  rather than a courtesy — a typo in a creator name or a licence URL is a
  compliance problem, not a cosmetic one. Nothing covered them before.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Attribution

  describe "svg_maps/0" do
    test "credits the project and links the repository" do
      svg = Attribution.svg_maps()

      assert svg.creator == "tarkov-dev-svg-maps contributors"
      assert svg.url == "https://github.com/the-hideout/tarkov-dev-svg-maps"
    end

    # The article was dropped when the credit line gained a per-map author, so
    # it now reads "by Shebuka · tarkov-dev-svg-maps contributors".
    test "the creator reads correctly mid-line" do
      refute String.starts_with?(Attribution.svg_maps().creator, "the ")
    end

    test "states the licence the repository actually carries" do
      svg = Attribution.svg_maps()

      assert svg.license == "CC BY-NC-SA 4.0"
      assert svg.license_url == "https://creativecommons.org/licenses/by-nc-sa/4.0/"
    end
  end

  describe "wiki/0" do
    # Pinned at 3.0 deliberately — Fandom dropped the version from its footer in
    # 2023 without relicensing. See the moduledoc.
    test "is pinned at 3.0 with a matching licence URL" do
      wiki = Attribution.wiki()

      assert wiki.creator == "Escape from Tarkov Wiki contributors"
      assert wiki.license == "CC BY-NC-SA 3.0"
      assert wiki.license_url == "https://creativecommons.org/licenses/by-nc-sa/3.0/"
    end
  end

  describe "every entry" do
    test "carries the full set of credit fields" do
      for source <- [Attribution.wiki(), Attribution.svg_maps()] do
        for key <- [:id, :name, :url, :creator, :license, :license_url] do
          assert Map.has_key?(source, key), "#{inspect(source.id)} is missing #{key}"
        end

        assert String.starts_with?(source.url, "https://")
        assert String.starts_with?(source.license_url, "https://")
      end
    end
  end
end
