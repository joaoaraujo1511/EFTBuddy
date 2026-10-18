defmodule EftBuddyWeb.AccessibilityTest do
  @moduledoc """
  The accessibility fixes from audit L30, pinned on the rendered HTML.

  None of these break anything a sighted mouse user would see, which is
  exactly why they regressed unnoticed before: a label that lost its `for`, a
  second `<h1>`, or a colour nudged back under 4.5:1 all still look fine. The
  behaviour that lives in `app.js` (moving focus into the opened rail, the pen
  key opening on focus) is covered by the live Playwright pass instead.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 2]

  alias EftBuddy.Chapters.ChapterPage
  alias EftBuddy.Repo
  alias EftBuddyWeb.AmmoLive.Index, as: AmmoLive
  alias EftBuddyWeb.CoreComponents

  defp doc(html), do: LazyHTML.from_document(html)
  defp all(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> all(selector) |> Enum.count()
  defp attr(html, selector, name), do: html |> all(selector) |> LazyHTML.attribute(name)

  describe "<.input>" do
    defp input_html(errors, type \\ "text") do
      form =
        to_form(%{"title" => "x"},
          as: :report,
          errors: Enum.map(errors, &{:title, {&1, []}}),
          action: :validate
        )

      render_component(&CoreComponents.input/1, field: form[:title], type: type, label: "Title")
    end

    test "the label names its input" do
      for type <- ["text", "textarea", "select"] do
        html =
          if type == "select",
            do:
              render_component(&CoreComponents.input/1,
                name: "pick",
                id: "pick",
                type: "select",
                label: "Pick",
                options: ["a"],
                value: "a"
              ),
            else: input_html([], type)

        id = if type == "select", do: "pick", else: "report_title"
        assert attr(html, "label", "for") == [id], "#{type}: label has no matching for"
      end
    end

    test "an error is tied to the field and marks it invalid" do
      html = input_html(["can't be blank"])

      assert attr(html, "input", "aria-describedby") == ["report_title-error"]
      assert attr(html, "input", "aria-invalid") == ["true"]
      assert html |> all("#report_title-error") |> LazyHTML.text() =~ "can't be blank"
    end

    test "a field with no error points at nothing" do
      html = input_html([])

      assert attr(html, "input", "aria-describedby") == []
      assert attr(html, "input", "aria-invalid") == []
      assert count(html, "#report_title-error") == 0
    end
  end

  describe "the shell" do
    setup %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/report-bug")
      %{html: html}
    end

    test "a skip link is the first focusable thing and targets <main>", %{html: html} do
      [first | _] = all(html, "a[href], button") |> Enum.to_list()
      assert LazyHTML.attribute(first, "href") == ["#main-content"]
      assert attr(html, "main", "id") == ["main-content"]
      assert attr(html, "main", "tabindex") == ["-1"]
    end

    test "the off-canvas rail is invisible below lg, so its links leave the tab order",
         %{html: html} do
      [class] = attr(html, "#left-rail", "class")
      assert class =~ ~r/(^|\s)invisible(\s|$)/
      assert class =~ "lg:visible"
    end

    test "the rail's open button says what it controls", %{html: html} do
      assert attr(html, "[data-shell-rail-open]", "aria-controls") == ["left-rail"]
      assert attr(html, "[data-shell-rail-open]", "aria-expanded") == ["false"]
    end

    test "a page without its own heading keeps the top bar's <h1>", %{html: html} do
      assert count(html, "h1") == 1
    end
  end

  describe "one <h1> per page" do
    test "the map page", %{conn: conn} do
      EftBuddy.Fixtures.game_map(%{normalized_name: "customs", name: "Customs"})
      {:ok, _view, html} = live(conn, ~p"/maps/customs")
      assert count(html, "h1") == 1
    end

    test "a storyline chapter", %{conn: conn} do
      content = %{
        "normalized_name" => "boreas",
        "chapter_name" => "Boreas",
        "wiki_title" => "Boreas",
        "wiki_link" => "https://escapefromtarkov.fandom.com/wiki/Boreas",
        "sections" => [
          %{
            "slug" => "guide",
            "level" => 2,
            "index" => "1",
            "files" => [],
            "heading" => "Guide",
            "wikitext" => "==Guide==\nHead north."
          }
        ]
      }

      %ChapterPage{}
      |> ChapterPage.changeset(%{
        normalized_name: "boreas",
        chapter_name: "Boreas",
        content: content
      })
      |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/storyline/boreas")
      assert count(html, "h1") == 1
    end
  end

  test "the bug form does not round-trip on every keystroke", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/report-bug")

    assert attr(html, "#bug-report-form input[name='bug_report[title]']", "phx-debounce") ==
             ["400"]

    assert attr(html, "#bug-report-form textarea", "phx-debounce") == ["400"]
  end

  describe "contrast" do
    # WCAG 2 relative luminance and contrast ratio.
    defp luminance("#" <> hex) do
      [r, g, b] =
        for <<c::binary-size(2) <- hex>> do
          v = String.to_integer(c, 16) / 255
          if v <= 0.03928, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
        end

      0.2126 * r + 0.7152 * g + 0.0722 * b
    end

    defp ratio(a, b) do
      {hi, lo} =
        Enum.min_max_by([luminance(a), luminance(b)], & &1) |> then(fn {l, h} -> {h, l} end)

      (hi + 0.05) / (lo + 0.05)
    end

    # `bg-rust/10` over a panel: the colour rust text actually sits on in a chip.
    defp tint(base, over, alpha) do
      "#" <>
        (Enum.zip(rgb(base), rgb(over))
         |> Enum.map_join(fn {b, o} ->
           (b * (1 - alpha) + o * alpha)
           |> round()
           |> Integer.to_string(16)
           |> String.pad_leading(2, "0")
         end))
    end

    defp rgb("#" <> hex), do: for(<<c::binary-size(2) <- hex>>, do: String.to_integer(c, 16))

    defp css_token(name) do
      css = File.read!("assets/css/app.css")
      [_, value] = Regex.run(~r/--color-#{name}:\s*(#[0-9a-fA-F]{6})/, css)
      String.downcase(value)
    end

    test "rust text clears 4.5:1 on every surface and in its own chip" do
      rust = css_token("rust")

      for surface <- ~w(ink-950 ink-900 ink-850 ink-800) do
        assert ratio(rust, css_token(surface)) >= 4.5, "rust on #{surface}"
      end

      assert ratio(rust, tint(css_token("ink-850"), rust, 0.10)) >= 4.5, "rust on bg-rust/10"
    end

    test "every penetration rating's digit clears 4.5:1 on its swatch" do
      fog = css_token("fog-50")

      for rating <- 0..6 do
        assert ratio(fog, AmmoLive.rating_color(rating)) >= 4.5, "rating #{rating}"
      end
    end

    test "the hover key in app.js shows the same swatches as the matrix" do
      js = File.read!("assets/js/app.js")

      for rating <- 0..6 do
        assert js =~ ~s(rating: #{rating}, color: "#{AmmoLive.rating_color(rating)}"),
               "PEN_SCALE rating #{rating} drifted from rating_color/1"
      end
    end
  end

  describe "the ammo penetration key" do
    alias EftBuddy.Ammo.Round

    setup %{conn: conn} do
      item = EftBuddy.Fixtures.item(%{name: "5.56x45mm M855"})

      Repo.insert!(%Round{
        external_id: "ammo-a11y",
        item_id: item.id,
        caliber: "Caliber556x45NATO",
        ammo_type: "bullet",
        damage: 54,
        penetration_power: 31,
        penetration_chance: 0.5,
        armor_damage: 37,
        ricochet_chance: 0.4,
        accuracy_modifier: 0.0,
        recoil_modifier: 0.0,
        initial_speed: 922.0,
        projectile_count: 1,
        light_bleed_modifier: 0.0,
        heavy_bleed_modifier: 0.0,
        stack_max_size: 60,
        tracer: false,
        tracer_color: "red"
      })

      {:ok, _view, html} = live(conn, ~p"/ammo")
      %{html: html}
    end

    test "is reachable by keyboard, not by hover alone", %{html: html} do
      assert html |> all("#ammo-view button[data-pen-key]") |> Enum.count() == 1
      assert attr(html, "[data-pen-key]", "aria-expanded") == ["false"]
    end

    test "each cell reads out its class, rating and meaning", %{html: html} do
      labels = attr(html, "[data-pen-rating]", "aria-label")
      roles = attr(html, "[data-pen-rating]", "role")

      assert length(labels) == 6
      assert Enum.all?(roles, &(&1 == "img"))
      assert Enum.all?(labels, &(&1 =~ ~r/^Class [1-6]: [0-6] of 6, .+/))
    end
  end
end
