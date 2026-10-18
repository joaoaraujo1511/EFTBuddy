defmodule EftBuddy.Wiki.LiveSnapshotsTest do
  @moduledoc """
  The wiki parsers and clients against trimmed copies of what the live wiki
  returned on 2026-10-18 (test/fixtures/wiki, see its README).

  All of these worked against the markup of the day and nothing guarded that
  (audit M24): the Events parser, contributor rosters, file licences, credit
  links, and the endgame chapter's keep-rule (26d0a10). A wiki edit that changes
  the shape they depend on now fails here instead of silently on the site.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Chapters.Sync, as: ChaptersSync
  alias EftBuddy.Credits
  alias EftBuddy.Events.Dump, as: EventsDump
  alias EftBuddy.Wiki.{Api, Contributors, FileLicense}

  @fixtures "test/fixtures/wiki"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
  defp json_fixture(name), do: name |> fixture() |> Jason.decode!()

  # Answer every wiki request with one recorded response body.
  defp serve(body), do: Req.Test.stub(EftBuddy.Wiki.DumpScript, &Req.Test.json(&1, body))

  describe "the Events page parser" do
    setup do
      %{events: EventsDump.parse_events_page(fixture("events_page.wikitext"))}
    end

    defp event(events, name), do: Enum.find(events, &(&1.name == name))
    defp quest_names(event), do: Enum.map(event.quests, & &1.name)

    test "one record per level-2 heading, newest first", %{events: events} do
      assert Enum.map(events, & &1.name) == [
               "Scourge Incursion",
               "Shifting Balance",
               "Icebreaker",
               "The Labyrinth",
               "Marathon",
               "Sanitar Event",
               "Halloween 2022",
               "June 2022 Pre-Wipe Event"
             ]

      assert Enum.map(events, & &1.position) == Enum.to_list(0..7)
    end

    test "the past-events divider splits active from past", %{events: events} do
      # The event whose body holds the divider is still active; everything below it is past.
      assert Enum.map(events, & &1.status) == ~w(active active past past past past past past)
    end

    test "dates, including a range, parse to the start day", %{events: events} do
      assert event(events, "Scourge Incursion").started_on == ~D[2026-10-16]
      assert event(events, "June 2022 Pre-Wipe Event").event_date == "20-27 June 2022"
      assert event(events, "June 2022 Pre-Wipe Event").started_on == ~D[2022-06-20]
    end

    test "banners and quotes", %{events: events} do
      scourge = event(events, "Scourge Incursion")
      assert scourge.banner_filename == "Hidden Route Banner.png"
      assert scourge.description =~ "TerraGroup underground complex"
      assert event(events, "Shifting Balance").description == nil
    end

    test "quest bullets become quests; other 'has been added' lines do not", %{events: events} do
      assert quest_names(event(events, "Scourge Incursion")) == [
               "Hidden Route",
               "A Simple Task in a Difficult Place",
               "Extending the Operation",
               "Information Trail",
               "Side Hustle",
               "Doxed"
             ]

      icebreaker = event(events, "Icebreaker")
      assert "Saving Private Roman" in quest_names(icebreaker)
      refute Enum.any?(quest_names(icebreaker), &(&1 in ["Icebreaker", "Boreas"]))

      changes = Enum.map(icebreaker.gameplay_changes, & &1.text)
      assert "Icebreaker location has been added." in changes
      assert "Story chapter Boreas has been added." in changes
    end

    test "an event with no 'Gameplay Changes' header still yields its quests", %{events: events} do
      assert length(event(events, "The Labyrinth").quests) == 16
    end

    test "a piped link takes its slug from the target and its name from the label",
         %{events: events} do
      [first | _] = event(events, "Marathon").quests

      assert first.name == "Marathon - From Beginning To End"
      assert first.wiki_title == "From Beginning To End"
      assert first.slug == "from-beginning-to-end"
    end

    test "a 'Temporary Quest ... can be started' bullet is a quest", %{events: events} do
      assert quest_names(event(events, "Sanitar Event")) == ["Letters"]
    end

    test "a word like 'Temporary' elsewhere does not make a quest", %{events: events} do
      # Halloween 2022 links "Temporary status effects"; it added no quests.
      assert event(events, "Halloween 2022").quests == []
    end

    test "the PvE availability note is captured", %{events: events} do
      assert event(events, "Marathon").availability_note == "Not available in the PvE game mode."
    end

    test "wikitable cells do not leak into the gameplay changes", %{events: events} do
      assert [only] = event(events, "Shifting Balance").gameplay_changes
      assert only.text =~ "Glukhar has moved from Reserve to Lighthouse"
    end
  end

  describe "contributor rosters" do
    test "a live roster: names sorted, anonymous edits counted" do
      serve(json_fixture("contributors.json"))

      rosters = Contributors.fetch(["Golden Swag", "The Punisher - Part 1"], Api.http_opts())

      assert rosters["Golden Swag"] == %{
               names: ["Lady Botris", "Lady Lostris", "Mehabr", "TalkingCactus"],
               anon: 12
             }

      assert rosters["The Punisher - Part 1"].anon == 0
    end

    test "continuations merge into one roster" do
      Req.Test.stub(EftBuddy.Wiki.DumpScript, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        {names, continue} =
          if conn.query_params["pccontinue"],
            do: {["Zed"], nil},
            else: {["Amy"], %{"pccontinue" => "6743|99", "continue" => "||"}}

        body = %{
          "query" => %{
            "pages" => [
              %{
                "title" => "Golden Swag",
                "anoncontributors" => 3,
                "contributors" => Enum.map(names, &%{"name" => &1})
              }
            ]
          }
        }

        Req.Test.json(conn, if(continue, do: Map.put(body, "continue", continue), else: body))
      end)

      assert Contributors.fetch(["Golden Swag"], Api.http_opts())["Golden Swag"] ==
               %{names: ["Amy", "Zed"], anon: 3}
    end
  end

  describe "file licences" do
    setup do
      FileLicense.clear_cache()
      on_exit(&FileLicense.clear_cache/0)
    end

    test "a live file page declaring CC BY-NC-SA 4.0 is creditable; the others say nothing" do
      serve(json_fixture("file_pages.json"))

      titles = [
        "File:GroundZero3DMapByRe3mr.png",
        "File:Hidden Route Banner.png",
        "File:Icebreaker Event.jpg"
      ]

      {licenses, 0} = FileLicense.fetch(titles, Api.http_opts())

      assert Map.keys(licenses) == ["File:GroundZero3DMapByRe3mr.png"]
      assert licenses["File:GroundZero3DMapByRe3mr.png"].label == "CC BY-NC-SA 4.0"
      assert licenses["File:GroundZero3DMapByRe3mr.png"].creditable
    end

    test "the uploader of a creditable image is found wherever it sits in a manifest" do
      license = FileLicense.parse("{{Copyright CC-BY-NC-SA 4.0}}")

      manifest = %{
        "sections" => [
          %{"files" => [%{"file" => "Map.png", "uploader" => "Re3mr", "license" => license}]},
          %{"files" => [%{"file" => "Icon.png", "uploader" => "Bot", "license" => nil}]}
        ]
      }

      assert FileLicense.image_uploaders(manifest) == ["Re3mr"]
    end
  end

  describe "credit links" do
    test "a profile link is an encoded wiki URL" do
      assert Credits.profile_url("Lady Botris") ==
               "https://escapefromtarkov.fandom.com/wiki/UserProfile:Lady_Botris"
    end

    test "a contributor's colour is stable and in range" do
      assert Credits.color_index("Mehabr") == Credits.color_index("Mehabr")
      assert Credits.color_index("Mehabr") in 0..5
    end
  end

  describe "the endgame chapter's keep-rule (26d0a10)" do
    setup do
      sections =
        for s <- json_fixture("the_ticket_sections.json"),
            do: %{index: s["index"], wikitext: s["wikitext"]}

      lead = %{index: "0", wikitext: "{{Infobox chapter}}"}

      guide = %{
        index: "tmpl:Template:The Ticket Section Savior Guide",
        wikitext: "===Talk to Mr. Kerman==="
      }

      %{page: [lead | sections] ++ [guide]}
    end

    defp kept(chapter, sections),
      do: chapter |> ChaptersSync.prune_sections(sections) |> Enum.map(& &1.index)

    test "The Ticket keeps its lead, its ending-badged blocks and its branch guides",
         %{page: page} do
      # Section 1 is the shared objective list, rendered nowhere; 2 is a
      # conditional block and 7 the block shared by every ending, both badged.
      assert kept(%{normalized_name: "the-ticket"}, page) ==
               ["0", "2", "7", "tmpl:Template:The Ticket Section Savior Guide"]
    end

    test "any other chapter is kept whole", %{page: page} do
      assert length(kept(%{normalized_name: "boreas"}, page)) == length(page)
    end

    test "a restructured Ticket that matches nothing is kept whole, with a warning" do
      plain = [%{index: "1", wikitext: "==Objectives==\n* Do it"}]

      capture_log(fn ->
        assert kept(%{normalized_name: "the-ticket"}, plain) == ["1"]
      end)
    end
  end
end
