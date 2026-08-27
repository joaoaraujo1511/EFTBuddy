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

  describe "ending_badges/1" do
    defp badge(name) do
      %{
        slug: String.downcase(name),
        label: "#{name} ending",
        file: %{"url" => "https://cdn/#{String.downcase(name)}.png"}
      }
    end

    test "every ending gets its wiki icon and its name" do
      html =
        render_component(&StorylineComponents.ending_badges/1,
          endings: Enum.map(~w(Savior Debtor Fallen), &badge/1)
        )

      assert html =~ "Savior ending"
      assert html =~ "Debtor ending"
      assert html =~ "https://cdn/fallen.png"
    end

    test "a badge with no resolved icon still names its ending" do
      html =
        render_component(&StorylineComponents.ending_badges/1,
          endings: [%{slug: "savior", label: "Savior ending", file: nil}]
        )

      assert html =~ "Savior ending"
      refute html =~ "<img"
    end
  end

  describe "ending_tabs/1" do
    defp ending_view(slug) do
      %{
        slug: slug,
        label: String.capitalize(slug),
        icon: %{"url" => "https://cdn/#{slug}.png"},
        guide: nil,
        rewards: nil
      }
    end

    defp tabs_html(active) do
      render_component(&StorylineComponents.ending_tabs/1,
        views: Enum.map(~w(savior debtor), &ending_view/1),
        active: active,
        href_for: fn view -> "/storyline/the-ticket?ending=#{view.slug}" end
      )
    end

    test "one link per ending, wearing that ending's icon" do
      html = tabs_html("savior")

      assert html =~ "/storyline/the-ticket?ending=savior"
      assert html =~ "/storyline/the-ticket?ending=debtor"
      assert html =~ "https://cdn/savior.png"
      assert html =~ "Debtor"
    end

    test "the tabs wear the same solid pill the ending badges do" do
      # Same four things named twice on the site; a reader who learned the
      # badges should recognise the tabs on sight.
      badges =
        render_component(&StorylineComponents.ending_badges/1, endings: [badge("Savior")])

      assert badges =~ "bg-ink-900"
      assert tabs_html("savior") =~ "bg-ink-900"
      assert tabs_html("savior") =~ ~s(data-phx-link="patch")
    end

    test "the active ending is the only one marked current" do
      html = tabs_html("debtor")

      assert [~s(aria-current="false"), ~s(aria-current="page")] =
               Regex.scan(~r/aria-current="\w+"/, html) |> List.flatten()
    end
  end

  describe "content_section/1" do
    defp plain_section(overrides \\ %{}) do
      Map.merge(
        %{
          dom_id: "guide-savior",
          slug: "savior_guide",
          heading: "Guide",
          level: 2,
          transcluded: true,
          endings: [],
          blocks: [%{kind: :prose, emphasis: false, text: "Talk to Prapor."}]
        },
        overrides
      )
    end

    test "an ordinary section renders its heading and blocks, and no badges" do
      html = render_component(&StorylineComponents.content_section/1, section: plain_section())

      assert html =~ "Guide"
      assert html =~ "Talk to Prapor."
      refute html =~ "ending"
    end

    test "a badged block names the endings it leads to, under its heading" do
      html =
        render_component(&StorylineComponents.content_section/1,
          section:
            plain_section(%{
              heading: "If you accept Mr. Kerman's offer",
              endings: Enum.map(~w(Savior Debtor), &badge/1)
            })
        )

      assert html =~ "If you accept Mr. Kerman&#39;s offer"
      assert html =~ "Savior ending"
      assert html =~ "https://cdn/debtor.png"
    end

    test "a bolded condition renders heavier than the body prose it governs" do
      html =
        render_component(&StorylineComponents.content_section/1,
          section:
            plain_section(%{
              blocks: [
                %{kind: :prose, emphasis: true, text: "If you gave Prapor the case"},
                %{kind: :prose, emphasis: false, text: "Hand over the cash."}
              ]
            })
        )

      assert html =~ ~r/class="[^"]*font-semibold[^"]*">\s*If you gave Prapor the case/
      refute html =~ ~r/class="[^"]*font-semibold[^"]*">\s*Hand over the cash/
    end
  end
end
