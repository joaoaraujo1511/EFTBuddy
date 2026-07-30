defmodule EftBuddyWeb.MapsLive.ShowLiveTest do
  @moduledoc """
  Rendered output of the map detail page, focused on the artwork credit.

  The credit line is a licence obligation on the SVG maps, so what it says —
  and, on the tile maps, what it does *not* say — is worth pinning.
  """
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EftBuddy.Fixtures

  @repo_url "https://github.com/the-hideout/tarkov-dev-svg-maps"

  defp svg_map(attrs \\ %{}) do
    Fixtures.game_map(
      Map.merge(
        %{
          normalized_name: "customs",
          name: "Customs",
          projection: "svg",
          image_author: "Shebuka",
          # Upstream writes the repo URL with a trailing slash; the credit has
          # to recognise it as the same place it already links.
          image_author_link: @repo_url <> "/"
        },
        attrs
      )
    )
  end

  defp tile_map(attrs \\ %{}) do
    Fixtures.game_map(
      Map.merge(
        %{
          normalized_name: "icebreaker",
          name: "Icebreaker",
          projection: "tile",
          tile_path: "https://assets.tarkov.dev/maps/icebreaker/06_infirmary/{z}/{x}/{y}.png",
          image_author: "TarkovBOT.eu",
          image_author_link: "https://tarkovbot.eu/"
        },
        attrs
      )
    )
  end

  describe "the SVG map credit" do
    setup %{conn: conn} do
      svg_map()
      {:ok, _view, html} = live(conn, ~p"/maps/customs")
      %{html: html}
    end

    test "names the artist maps.json credits", %{html: html} do
      assert html =~ "Interactive map by"
      assert html =~ "Shebuka"
    end

    test "links the project's contributor list", %{html: html} do
      assert html =~ "tarkov-dev-svg-maps contributors"
      assert html =~ @repo_url
    end

    test "states the licence the artwork actually carries", %{html: html} do
      assert html =~ "CC BY-NC-SA 4.0"
      assert html =~ "creativecommons.org/licenses/by-nc-sa/4.0/"
    end

    # The author's own link upstream *is* the repo, so linking the name too
    # would put two links to one destination in a single line.
    test "the author is plain text when its link is the repo", %{html: html} do
      refute html =~ ~s(href="#{@repo_url}/")
    end
  end

  describe "the tile map credit" do
    setup %{conn: conn} do
      tile_map()
      {:ok, _view, html} = live(conn, ~p"/maps/icebreaker")
      %{html: html}
    end

    test "names its own author and links them", %{html: html} do
      assert html =~ "TarkovBOT.eu"
      assert html =~ ~s(href="https://tarkovbot.eu/")
    end

    test "still links the contributor list", %{html: html} do
      assert html =~ "tarkov-dev-svg-maps contributors"
    end

    # The tile art carries no stated licence anywhere upstream. Showing one
    # would assert a grant neither TarkovBOT.eu nor Tarkov.dev has made.
    test "claims no licence", %{html: html} do
      refute html =~ "CC BY-NC-SA"
      refute html =~ "creativecommons.org"
    end
  end

  describe "credit_author_href/2" do
    alias EftBuddyWeb.MapsLive.Show

    test "returns nil when the author link is the source's own URL" do
      source = %{url: @repo_url}

      assert Show.credit_author_href(%{image_author_link: @repo_url}, source) == nil
      assert Show.credit_author_href(%{image_author_link: @repo_url <> "/"}, source) == nil
    end

    test "returns the link when it points somewhere else" do
      assert Show.credit_author_href(
               %{image_author_link: "https://tarkovbot.eu/"},
               %{url: @repo_url}
             ) == "https://tarkovbot.eu/"
    end

    test "handles a map with no author link at all" do
      assert Show.credit_author_href(%{image_author_link: nil}, %{url: @repo_url}) == nil
    end
  end
end
