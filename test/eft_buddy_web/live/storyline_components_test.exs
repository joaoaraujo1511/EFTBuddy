defmodule EftBuddyWeb.StorylineComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EftBuddyWeb.StorylineComponents

  defp item(page, opts \\ []) do
    %{
      name: Keyword.get(opts, :name, page),
      page: page,
      amount: Keyword.get(opts, :amount),
      requirement: Keyword.get(opts, :requirement),
      found_in_raid: Keyword.get(opts, :fir)
    }
  end

  describe "chapter_items/1" do
    test "real items link into the Items tab and show the API image in a tier tile" do
      db = %{
        name: "Note for Kozlov",
        image_512px_link: "https://cdn/api/note-512.png",
        icon_link: "https://cdn/api/note-icon.png",
        background_color: "violet"
      }

      html =
        render_component(&StorylineComponents.chapter_items/1,
          items: [item("Note for Kozlov", fir: true)],
          item_index: %{"Note for Kozlov" => db}
        )

      # Links into the Items tab and uses the API (512px) image.
      assert html =~ "/items?q=Note+for+Kozlov"
      assert html =~ "https://cdn/api/note-512.png"
      # Tier background from the DB item's background_color, now applied as a
      # utility class (`.item-bg-violet`) rather than an inline style.
      assert html =~ "item-bg-violet"
      assert html =~ "FiR"
    end

    test "non-items render as plain text — no link, no image" do
      html =
        render_component(&StorylineComponents.chapter_items/1,
          items: [item("building materials")],
          item_index: %{}
        )

      assert html =~ "building materials"
      refute html =~ "/items?q="
      refute html =~ "<img"
    end

    test "an item missing from the index (DB unavailable) degrades to plain text" do
      html =
        render_component(&StorylineComponents.chapter_items/1,
          items: [item("Some Real Item")],
          item_index: %{}
        )

      assert html =~ "Some Real Item"
      refute html =~ "<img"
    end
  end
end
