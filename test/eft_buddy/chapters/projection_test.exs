defmodule EftBuddy.Chapters.ProjectionTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Chapters.Projection

  # Build a string-keyed manifest the way it's stored in the
  # `wiki_chapters.content` JSONB column (and read back by Ecto).
  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "normalized_name" => "boreas",
        "chapter_name" => "Boreas",
        "wiki_title" => "Boreas",
        "wiki_link" => "https://escapefromtarkov.fandom.com/wiki/Boreas",
        "banner" => %{"url" => "https://cdn/banner.png"},
        "related_links" => [
          %{"title" => "Some Quest", "slug" => "some-quest"},
          %{"oops" => true}
        ],
        "sections" => [
          %{
            "slug" => "lead",
            "level" => 0,
            "index" => "0",
            "heading" => "(lead / infobox)",
            "wikitext" => "infobox stuff",
            "files" => []
          },
          %{
            "slug" => "description",
            "level" => 2,
            "index" => "1",
            "heading" => "Description",
            "wikitext" => "{{quote|A cold and unforgiving place.|Narrator}}",
            "files" => []
          },
          %{
            "slug" => "guide",
            "level" => 2,
            "index" => "2",
            "heading" => "Guide",
            "wikitext" =>
              "Head north to the lighthouse.\n<gallery>\nFile:Shot.png|A screenshot\n</gallery>",
            "files" => [
              %{"wiki_filename" => "Shot.png", "url" => "https://cdn/shot.png", "banner" => false}
            ]
          }
        ]
      },
      overrides
    )
  end

  describe "project/1" do
    test "drops the lead/infobox section but keeps the real sections in order" do
      slugs = Projection.project(manifest()).content_sections |> Enum.map(& &1.slug)
      assert slugs == ["description", "guide"]
    end

    test "extracts the infobox banner url, or nil when absent" do
      assert Projection.project(manifest()).banner == %{url: "https://cdn/banner.png"}
      assert Projection.project(manifest(%{"banner" => nil})).banner == nil
    end

    test "pulls the lore summary out of the Description {{quote}}" do
      assert Projection.project(manifest()).summary == "A cold and unforgiving place."
    end

    test "normalizes related links and drops malformed entries" do
      assert Projection.project(manifest()).related_links ==
               [%{title: "Some Quest", slug: "some-quest"}]
    end

    test "counts what the page will render, not what the wikitext holds" do
      projected = Projection.project(manifest())

      assert projected.image_count == 1
      assert projected.objective_count == 0
    end

    test "passes identity fields through and retains the raw sections" do
      projected = Projection.project(manifest())
      assert projected.normalized_name == "boreas"
      assert projected.chapter_name == "Boreas"
      assert projected.wiki_title == "Boreas"
      assert length(projected.sections) == 3
    end

    test "returns nil for non-map input" do
      assert Projection.project(:nope) == nil
    end

    test "marks sections captured from a transcluded template" do
      assert Enum.map(projected(ticket_sections()), & &1.transcluded) == [
               false,
               true,
               true,
               false
             ]
    end
  end

  describe "ending badges" do
    test "reads the endings a conditional block is badged with off its heading" do
      [_objectives, accept, refuse, _rewards] = projected(branch_sections())

      assert Enum.map(accept.endings, & &1.slug) == ["savior", "debtor"]
      assert Enum.map(accept.endings, & &1.label) == ["Savior ending", "Debtor ending"]

      assert Enum.map(accept.endings, & &1.file["url"]) == [
               "https://cdn/savior.png",
               "https://cdn/debtor.png"
             ]

      assert Enum.map(refuse.endings, & &1.slug) == ["survivor"]
    end

    test "a heading with no file references carries no badges" do
      [objectives, _accept, _refuse, rewards] = projected(branch_sections())

      assert objectives.endings == []
      assert rewards.endings == []
    end

    test "a badge with no caption falls back to its filename" do
      assert [%{slug: "savior", label: "Savior"}] =
               badges_of("===Ending [[File:Savior icon.png|74x74px|link=]]===\n* step")
    end

    test "sizes and named options are never mistaken for the caption" do
      assert [%{slug: "savior", label: "Savior ending"}] =
               badges_of("===Ending [[File:Savior icon.png|74x74px|Savior ending|link=]]===\n* x")
    end

    test "the same ending badged twice counts once" do
      wikitext =
        "===Ending [[File:Savior icon.png|Savior ending|74x74px|link=]]" <>
          "[[File:Savior icon.png|Savior ending|74x74px|link=]]===\n* step"

      assert [%{slug: "savior"}] = badges_of(wikitext)
    end

    test "only the section's OWN heading is read, not a heading further down" do
      wikitext = "==Objectives==\n* step\n===Sub [[File:Savior icon.png|Savior ending]]===\n* x"

      assert badges_of(wikitext) == []
    end
  end

  describe "branch_objectives/2" do
    test "keeps the blocks the wiki badged, in page order" do
      assert Enum.map(branch(~w(savior debtor survivor fallen)), & &1.slug) ==
               ["accept", "refuse"]
    end

    test "a chapter with no endings page has no branch objectives" do
      assert branch([]) == []
    end

    test "a block badged with something that is not an ending is not one" do
      # Every badge must name a real ending, or an unrelated image in some
      # other chapter's heading would turn that section into an objective
      # block it has nothing to do with.
      assert Enum.map(branch(~w(savior survivor fallen)), & &1.slug) == ["refuse"]
    end

    test "tolerates a missing section list" do
      assert Projection.branch_objectives(nil, ["savior"]) == []
    end
  end

  describe "ending_views/2" do
    defp views(ending_slugs \\ ~w(savior debtor)) do
      Projection.ending_views(
        projected(ticket_sections()),
        Enum.map(ending_slugs, &ending_page_section/1)
      )
    end

    test "one view per ending, pairing that ending's guide with its rewards" do
      assert [savior, debtor] = views()

      assert savior.slug == "savior"
      assert savior.label == "Savior"
      assert savior.guide.heading == "Guide for the Savior ending"
      assert savior.guide.dom_id == "guide-savior"
      assert savior.rewards.heading == "Rewards"
      assert savior.rewards.dom_id == "rewards-savior"
      assert debtor.guide.dom_id == "guide-debtor"
    end

    test "the guide is the branch walkthrough the chapter transcludes" do
      [savior, _debtor] = views()

      assert savior.guide.transcluded
      assert [%{kind: :heading, text: "Talk to Mr. Kerman"} | _] = savior.guide.blocks
    end

    test "the ending's icon labels the tab instead of opening the panel" do
      [savior, _debtor] = views()

      assert savior.icon["url"] == "https://cdn/savior.png"
      refute Enum.any?(savior.rewards.blocks, &(&1.kind == :gallery))
    end

    test "the rewards panel drops the sub-heading its own title repeats" do
      [savior, _debtor] = views()

      assert Enum.map(savior.rewards.blocks, & &1.kind) == [:prose, :list]
    end

    test "an ending the chapter has no guide for still gets its rewards" do
      assert [%{slug: "survivor", guide: nil, rewards: %{heading: "Rewards"}}] =
               views(["survivor"])
    end

    test "no endings page, no views" do
      assert Projection.ending_views(projected(ticket_sections()), nil) == []
    end
  end

  defp badges_of(wikitext) do
    section = %{
      "slug" => "x",
      # Level 3, matching the `===` headings below: a section whose own
      # heading is DEEPER than its recorded level parses as a sub-heading
      # and stops the parse, leaving no blocks and no section at all.
      "level" => 3,
      "index" => "1",
      "heading" => "Heading",
      "wikitext" => wikitext,
      "files" => [file("Savior icon.png", "https://cdn/savior.png")]
    }

    [only] = projected([section])
    only.endings
  end

  defp branch(ending_slugs),
    do: Projection.branch_objectives(projected(branch_sections()), ending_slugs)

  # An Endings-page section as the projection hands it over: the ending's
  # icon alone, its outcome blurb, then a "Rewards" sub-heading and the
  # rewards themselves.
  defp ending_page_section(slug) do
    %{
      dom_id: "section-#{slug}",
      slug: slug,
      heading: String.capitalize(slug),
      level: 2,
      transcluded: false,
      endings: [],
      blocks: [
        %{
          kind: :gallery,
          images: [%{file: %{"url" => "https://cdn/#{slug}.png"}, caption: nil}]
        },
        %{kind: :prose, emphasis: false, text: "You escaped from Tarkov."},
        %{kind: :heading, level: 3, text: "Rewards"},
        %{kind: :list, ordered: false, items: [%{level: 1, text: "A dogtag"}]}
      ]
    }
  end

  # A cut-down "The Ticket" Objectives fork: the shared list, two
  # conditional blocks each badged in its heading with the endings it leads
  # to, and an unbadged section after the fork.
  defp branch_sections do
    [
      plain_section("objectives", 2, "Objectives"),
      badged_section("accept", "If you accept Mr. Kerman's offer", ["Savior", "Debtor"]),
      badged_section("refuse", "If you refuse Mr. Kerman's offer", ["Survivor"]),
      plain_section("rewards", 2, "Rewards")
    ]
  end

  defp plain_section(slug, level, heading) do
    %{
      "slug" => slug,
      "level" => level,
      "index" => "1",
      "heading" => heading,
      "wikitext" =>
        "#{String.duplicate("=", level)}#{heading}#{String.duplicate("=", level)}\n* A step",
      "files" => []
    }
  end

  defp badged_section(slug, heading, endings) do
    badges =
      Enum.map_join(endings, &"[[File:#{&1} icon.png|#{&1} ending|74x74px|link=]]")

    %{
      "slug" => slug,
      "level" => 3,
      "index" => "2",
      "heading" => heading,
      "wikitext" => "===#{heading} #{badges}===\n* A step",
      "files" =>
        Enum.map(endings, &file("#{&1} icon.png", "https://cdn/#{String.downcase(&1)}.png"))
    }
  end

  defp projected(sections) do
    manifest(%{"sections" => sections})
    |> Projection.project()
    |> Map.fetch!(:content_sections)
  end

  # A cut-down "The Ticket": a Guide section introducing a tabber (prose +
  # one icon per branch), the two branch guides transcluded into it, and the
  # shared closing step that follows them on the page.
  defp ticket_sections do
    [
      %{
        "slug" => "lead",
        "level" => 0,
        "index" => "0",
        "heading" => "(lead / infobox)",
        "wikitext" => "infobox stuff",
        "files" => []
      },
      %{
        "slug" => "guide",
        "level" => 2,
        "index" => "8",
        "heading" => "Guide",
        "wikitext" =>
          "Use the buttons below to select the ending you want to pursue.\n" <>
            "<li>[[File:Savior icon.png|120x120px]]</li>\n" <>
            "<li>[[File:Debtor icon.png|120x120px]]</li>",
        "files" => [
          file("Savior icon.png", "https://cdn/savior.png"),
          file("Debtor icon.png", "https://cdn/debtor.png")
        ]
      },
      %{
        "slug" => "savior-guide",
        "level" => 2,
        "index" => "tmpl:Template:The_Ticket_Section_Savior_Guide",
        "heading" => "The_Ticket_Section_Savior_Guide",
        "wikitext" => "===Talk to Mr. Kerman===\nVisit the laptop screen.",
        "files" => []
      },
      %{
        "slug" => "debtor-guide",
        "level" => 2,
        "index" => "tmpl:Template:The_Ticket_Section_Debtor_Guide",
        "heading" => "The_Ticket_Section_Debtor_Guide",
        "wikitext" => "===Talk to Prapor===\nVisit the trader screen.",
        "files" => []
      },
      %{
        "slug" => "escape-from-tarkov",
        "level" => 3,
        "index" => "20",
        "heading" => "Escape from Tarkov",
        "wikitext" => "Board the boat.",
        "files" => []
      }
    ]
  end

  defp file(name, url), do: %{"wiki_filename" => name, "url" => url, "banner" => false}
end
