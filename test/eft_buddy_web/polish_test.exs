defmodule EftBuddyWeb.PolishTest do
  @moduledoc "Audit L31: the link-preview image, the footer build id and chapter icons."
  use EftBuddyWeb.ConnCase, async: false

  alias EftBuddyWeb.StorylineComponents

  describe "the link-preview image" do
    test "is a 1200x630 PNG, which previews render and SVG is not", %{conn: conn} do
      html = conn |> get(~p"/report-bug") |> html_response(200)

      [content] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("meta[property='og:image']")
        |> LazyHTML.attribute("content")

      assert content =~ ~r{/images/og-image\.png$}
      assert html =~ ~s(name="twitter:card" content="summary_large_image")

      # The PNG header carries the size: 8-byte signature, then the IHDR chunk.
      png = File.read!("priv/static/images/og-image.png")
      assert <<0x89, "PNG", _::binary-size(12), width::32, height::32, _::binary>> = png
      assert {width, height} == {1200, 630}
    end
  end

  describe "the footer" do
    setup do
      previous = System.get_env("GIT_SHA")

      on_exit(fn ->
        if previous, do: System.put_env("GIT_SHA", previous), else: System.delete_env("GIT_SHA")
      end)
    end

    test "names the commit the build came from, not the app's static vsn", %{conn: conn} do
      System.put_env("GIT_SHA", "0123456789abcdef0123456789abcdef01234567")

      html = conn |> get(~p"/report-bug") |> html_response(200)

      assert html =~ "build 0123456"
      refute html =~ "0123456789abcdef"
      refute html =~ "v0.1.0"
    end

    test "says dev for a working tree", %{conn: conn} do
      System.delete_env("GIT_SHA")
      assert conn |> get(~p"/report-bug") |> html_response(200) =~ "build dev"
    end
  end

  describe "chapter_icon_src/1" do
    test "points at a vendored icon and ignores slugs with none" do
      assert StorylineComponents.chapter_icon_src(%{normalized_name: "boreas"}) ==
               "/images/chapters/boreas.webp"

      assert StorylineComponents.chapter_icon_src(%{normalized_name: "no-such-chapter"}) == nil
      assert StorylineComponents.chapter_icon_src(%{}) == nil
    end

    test "a digested copy is not mistaken for a chapter" do
      refute StorylineComponents.chapter_icon_src(%{
               normalized_name: "boreas-fb68a2e39f057a81f121d70fea9c2954"
             })
    end

    test "lists the directory once, not per render" do
      StorylineComponents.chapter_icon_src(%{normalized_name: "boreas"})
      icons = :persistent_term.get({StorylineComponents, :chapter_icons})

      assert MapSet.member?(icons, "boreas")
      refute Enum.any?(icons, &(&1 =~ ~r/-[0-9a-f]{32}$/))
    end
  end
end
