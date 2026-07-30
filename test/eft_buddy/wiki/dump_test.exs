defmodule EftBuddy.Wiki.DumpTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.Dump

  describe "build_db_index/1 and build_quest/2" do
    test "derives slug and wiki link for an unmatched (WIP) quest" do
      quest = Dump.build_quest("Golden Swag", %{})

      assert quest.name == "Golden Swag"
      assert quest.normalized_name == "golden-swag"
      assert quest.wiki_title == "Golden Swag"
      assert quest.wiki_link == "https://escapefromtarkov.fandom.com/wiki/Golden_Swag"
      assert quest.id == nil
      assert quest.wip
    end

    test "flags WIP only when the title matches no DB task" do
      index = Dump.build_db_index([%{id: "u1", name: "Known", normalized_name: "known"}])
      matched = Dump.build_quest("Known", index)

      refute matched.wip
      assert matched.id == "u1"
      assert matched.normalized_name == "known"

      assert Dump.build_quest("New Quest", index).wip
    end

    test "matches via the NAME slug when the API normalizedName diverges (apostrophe)" do
      # Regression: tarkov.dev deletes the apostrophe ("developers-...")
      # while our slugger dashes it ("developer-s-..."). Matching on the
      # name slug recognises the quest as API-backed instead of WIP, and
      # the manifest adopts the DB slug so it dedups + enriches correctly.
      index =
        Dump.build_db_index([
          %{
            id: "u",
            name: "Developer's Secrets - Part 1",
            normalized_name: "developers-secrets-part-1"
          }
        ])

      quest = Dump.build_quest("Developer's Secrets - Part 1", index)

      refute quest.wip
      assert quest.id == "u"
      assert quest.normalized_name == "developers-secrets-part-1"
    end

    test "faction variants that share a display name key on the suffix-less base" do
      # Two API tasks, same name, faction-suffixed slugs; one wiki page.
      # The shared wiki row must key on the BASE slug (the wiki page's own
      # slug) so BOTH faction variants' name slug resolves to it —
      # otherwise one faction's task can't find the shared guide.
      index =
        Dump.build_db_index([
          %{id: "b", name: "Drip-Out - Part 1", normalized_name: "drip-out-part-1-bear"},
          %{id: "u", name: "Drip-Out - Part 1", normalized_name: "drip-out-part-1-usec"}
        ])

      quest = Dump.build_quest("Drip-Out - Part 1", index)

      refute quest.wip
      assert quest.normalized_name == "drip-out-part-1"
    end

    test "a quest genuinely named '… Bear' is not mistaken for a faction variant" do
      # "Polar Bear" slugs to "polar-bear"; the slug EQUALS the name slug
      # (no extra `-bear` disambiguation tail), so it must be left intact
      # and match on the canonical key — not stripped to "polar".
      index =
        Dump.build_db_index([%{id: "p", name: "Polar Bear", normalized_name: "polar-bear"}])

      quest = Dump.build_quest("Polar Bear", index)

      refute quest.wip
      assert quest.normalized_name == "polar-bear"
    end

    test "the canonical normalized_name key wins over a name-slug collision" do
      index =
        Dump.build_db_index([
          %{id: "a", name: "Alpha", normalized_name: "alpha"},
          %{id: "b", name: "Alpha Two", normalized_name: "alpha"}
        ])

      # "alpha" resolves to the row whose normalized_name IS "alpha".
      assert Dump.build_quest("Alpha", index).id == "a"
    end

    test "accented quest names match the transliterated DB slug" do
      # tarkov.dev stores "cafe"; the wiki title is "Café". The name slug
      # must transliterate so the quest matches and isn't flagged WIP.
      index = Dump.build_db_index([%{id: "u", name: "Café", normalized_name: "cafe"}])
      refute Dump.build_quest("Café", index).wip
    end

    test "strips the wiki '(quest)' disambiguator so it matches its API task" do
      # The wiki titles these pages "Immunity (quest)" / "Reserve (quest)"
      # to disambiguate from the skill/map of the same name. Without
      # stripping, the slug ("immunity-quest") misses the API task and the
      # page lands as a duplicate WIP that steals the guide.
      index = Dump.build_db_index([%{id: "i", name: "Immunity", normalized_name: "immunity"}])
      quest = Dump.build_quest("Immunity (quest)", index)

      refute quest.wip
      assert quest.id == "i"
      assert quest.normalized_name == "immunity"
      assert quest.name == "Immunity"
      # The original title is retained for fetching/linking the page.
      assert quest.wiki_title == "Immunity (quest)"
      assert quest.wiki_link == "https://escapefromtarkov.fandom.com/wiki/Immunity_(quest)"
    end

    test "a '(quest)'-suffixed page with no API task is still cleaned for its WIP slug" do
      quest = Dump.build_quest("Bloodhounds (quest)", %{})

      assert quest.wip
      assert quest.name == "Bloodhounds"
      assert quest.normalized_name == "bloodhounds"
      assert quest.wiki_title == "Bloodhounds (quest)"
    end
  end

  describe "quest_title?/1" do
    test "rejects the category's non-quest index pages" do
      refute Dump.quest_title?("Quest")
      refute Dump.quest_title?("Quests")
      refute Dump.quest_title?(" quest ")
    end

    test "accepts real quest titles" do
      assert Dump.quest_title?("Golden Swag")
      assert Dump.quest_title?("Immunity (quest)")
    end
  end

  describe "normalize_filename via parse_section/3 (MediaWiki canonical form)" do
    test "underscores become spaces and the first letter is upcased" do
      parsed =
        Dump.parse_section(
          %{index: "1", heading: "Guide", level: "2"},
          "[[File:some_shot.png|cap]]",
          false
        )

      assert [%{file: "Some shot.png"}] = parsed.files
    end
  end

  describe "sanitize_dirname/1" do
    test "replaces filesystem-illegal characters and collapses whitespace" do
      assert Dump.sanitize_dirname(~s(A/B:C?"  D)) == "A-B-C-- D"
      assert Dump.sanitize_dirname("Golden Swag") == "Golden Swag"
    end
  end

  describe "parse_section/3" do
    test "level-1 list items become objectives; nested items don't" do
      parsed =
        Dump.parse_section(
          %{index: "1", heading: "Objectives", level: "2"},
          "* Find the key\n** sub note\n* Extract",
          false
        )

      assert parsed.section.slug == "objectives"
      assert Enum.map(parsed.objectives, & &1.text) == ["Find the key", "Extract"]
      assert Enum.map(parsed.objectives, & &1.index) == [1, 2]
    end

    test "lead heading maps to the 'lead' slug" do
      parsed =
        Dump.parse_section(%{index: "0", heading: "(lead / infobox)", level: "0"}, "", false)

      assert parsed.section.slug == "lead"
    end

    test "file refs are annotated with the preceding objective" do
      parsed =
        Dump.parse_section(
          %{index: "1", heading: "Guide", level: "2"},
          "* Plant the marker\n[[File:Spot.png|the spot]]",
          false
        )

      assert [file] = parsed.files
      assert file.file == "Spot.png"
      assert file.caption == "the spot"
      assert file.objective == 1
      assert file.objective_text == "Plant the marker"
    end

    test "<gallery> entries are captured as files" do
      parsed =
        Dump.parse_section(
          %{index: "1", heading: "Guide", level: "2"},
          "<gallery>\nFile:A.png|first\nFile:B.png|second\n</gallery>",
          false
        )

      assert Enum.map(parsed.files, & &1.file) == ["A.png", "B.png"]
      assert Enum.map(parsed.files, & &1.caption) == ["first", "second"]
    end

    test "skip_table_files? drops [[File:]] icons inside a wikitable" do
      wikitext = "{|\n![[File:Icon.png]]\n|}\n* obj\n[[File:Real.png]]"

      kept = Dump.parse_section(%{index: "1", heading: "G", level: "2"}, wikitext, false)
      dropped = Dump.parse_section(%{index: "1", heading: "G", level: "2"}, wikitext, true)

      assert "Icon.png" in Enum.map(kept.files, & &1.file)
      assert "Real.png" in Enum.map(kept.files, & &1.file)

      refute "Icon.png" in Enum.map(dropped.files, & &1.file)
      assert "Real.png" in Enum.map(dropped.files, & &1.file)
    end
  end

  describe "build_manifest/4" do
    defp lead(wikitext) do
      %{
        section: %{index: "0", heading: "(lead / infobox)", level: "0", slug: "lead"},
        objectives: [],
        files: [],
        wikitext: wikitext
      }
    end

    defp quest(overrides \\ %{}) do
      Map.merge(
        %{id: nil, name: "Q", normalized_name: "q", wiki_title: "Q", wiki_link: "l", wip: false},
        overrides
      )
    end

    test "extracts given_by from the infobox and carries the WIP flag + counts" do
      objectives_section = %{
        section: %{index: "1", heading: "Objectives", level: "2", slug: "objectives"},
        objectives: [%{index: 1, text: "Do it"}],
        files: [
          %{
            file: "S.png",
            caption: nil,
            preceding_text: nil,
            objective: 1,
            objective_text: "Do it"
          }
        ],
        wikitext: "* Do it"
      }

      parsed = [lead("|given by = [[Skier]]\n"), objectives_section]
      manifest = Dump.build_manifest(quest(%{wip: true}), "Q", parsed, %{})

      assert manifest.given_by == "Skier"
      assert manifest.wip == true
      assert manifest.summary.total_objectives == 1
      assert manifest.summary.total_files == 1
      assert [_lead, objs] = manifest.sections
      assert objs.slug == "objectives"
    end

    test "serialize_file pulls the resolved url from the info map keyed by File: title" do
      file = %{
        file: "S.png",
        caption: "cap",
        preceding_text: nil,
        objective: nil,
        objective_text: nil
      }

      section = %{
        section: %{index: "1", heading: "G", level: "2", slug: "g"},
        objectives: [],
        files: [file],
        wikitext: ""
      }

      info_map = %{
        "File:S.png" => %{
          "url" => "https://cdn/s.png",
          "mime" => "image/png",
          "width" => 1,
          "height" => 2
        }
      }

      manifest = Dump.build_manifest(quest(), "Q", [section], info_map)

      [serialized] = hd(manifest.sections).files
      assert serialized.url == "https://cdn/s.png"
      assert serialized.wiki_title == "File:S.png"
    end
  end

  describe "blacklist_reason/1" do
    test "flags a page carrying the {{Historical content}} notice as :historical" do
      lead = "{{Historical content}}\n{{Infobox quest\n|given by =[[Therapist]]\n}}\n"
      assert Dump.blacklist_reason(lead) == :historical
    end

    test "matches the historical template case- and whitespace-insensitively, with params" do
      assert Dump.blacklist_reason("{{ Historical Content }}") == :historical
      assert Dump.blacklist_reason("{{historical content|reason=cut}}") == :historical
    end

    test "matches MediaWiki-equivalent underscore / multi-space template names" do
      assert Dump.blacklist_reason("{{Historical_content}}") == :historical
      assert Dump.blacklist_reason("{{Historical  content}}") == :historical
    end

    test "ignores a commented-out notice / giver so a live quest isn't pruned" do
      assert Dump.blacklist_reason("<!-- {{Historical content}} -->\n|given by =[[Therapist]]\n") ==
               nil

      assert Dump.blacklist_reason("{{Infobox quest\n<!-- |given by =[[Ref]] -->\n}}") == nil
    end

    test "flags a quest given by the trader Ref as :ref" do
      assert Dump.blacklist_reason("{{Infobox quest\n|given by =[[Ref]]\n}}") == :ref
    end

    test "flags Ref even when listed among several givers" do
      assert Dump.blacklist_reason("|given by = [[Skier]] or [[Ref]]\n") == :ref
    end

    test "does not flag a normal quest" do
      assert Dump.blacklist_reason("{{Infobox quest\n|given by =[[Therapist]]\n}}") == nil
      assert Dump.blacklist_reason("|given by = [[Prapor]]\n") == nil
    end

    test "a giver name merely containing 'ref' (no word boundary) is not flagged" do
      assert Dump.blacklist_reason("|given by = [[Referee]]\n") == nil
    end

    test "historical content takes precedence over the Ref giver check" do
      assert Dump.blacklist_reason("{{Historical content}}\n|given by =[[Ref]]\n") == :historical
    end

    test "returns nil for empty or non-binary input" do
      assert Dump.blacklist_reason("") == nil
      assert Dump.blacklist_reason(nil) == nil
    end
  end

  describe "run/2 orchestration" do
    defp recording_writer do
      test_pid = self()

      fn quest, manifest ->
        send(test_pid, {:wrote, quest.normalized_name, manifest})
        :ok
      end
    end

    defp raw_sections do
      [
        %{index: "0", heading: "(lead / infobox)", level: "0", wikitext: "|image = Banner.png\n"},
        %{index: "1", heading: "Objectives", level: "2", wikitext: "* Do it\n[[File:Shot.png]]"}
      ]
    end

    test "fetch -> parse -> resolve -> write, returning summary counts" do
      quests = [Dump.build_quest("Alpha", %{})]

      resolve = fn titles ->
        # the lead banner (WIP quest) + the objective screenshot
        assert "File:Banner.png" in titles
        assert "File:Shot.png" in titles
        Map.new(titles, fn t -> {t, %{"url" => "https://cdn/x"}} end)
      end

      result =
        Dump.run(quests,
          fetch: fn _q -> {:ok, raw_sections()} end,
          resolve: resolve,
          write: recording_writer()
        )

      assert result.summary == %{processed: 1, failed: 0, skipped: 0, resolved: 2}
      assert_received {:wrote, "alpha", manifest}
      assert manifest.wip == true
    end

    test "isolates failures: a fetch error fails just that quest" do
      quests = [Dump.build_quest("Good", %{}), Dump.build_quest("Bad", %{})]

      result =
        Dump.run(quests,
          fetch: fn
            %{name: "Bad"} -> {:error, :boom}
            _ -> {:ok, raw_sections()}
          end,
          resolve: fn titles -> Map.new(titles, &{&1, %{}}) end,
          write: fn _q, _m -> :ok end
        )

      assert result.summary.processed == 1
      assert result.summary.failed == 1
      assert [%{slug: "bad", reason: :boom}] = result.failures
    end

    test "a {:skip, reason} fetch drops the quest: no write, recorded as skipped" do
      quests = [Dump.build_quest("Keep", %{}), Dump.build_quest("Drop", %{})]
      test_pid = self()

      result =
        Dump.run(quests,
          fetch: fn
            %{name: "Drop"} -> {:skip, :ref}
            _ -> {:ok, raw_sections()}
          end,
          resolve: fn titles -> Map.new(titles, &{&1, %{}}) end,
          write: fn quest, _m ->
            send(test_pid, {:wrote, quest.normalized_name})
            :ok
          end
        )

      assert result.summary.processed == 1
      assert result.summary.skipped == 1
      assert result.summary.failed == 0
      assert [%{slug: "drop", reason: :ref}] = result.skipped
      # The kept quest is written; the skipped one never reaches the writer.
      assert_received {:wrote, "keep"}
      refute_received {:wrote, "drop"}
    end

    test "dry_run skips resolution but still writes the manifest" do
      quests = [Dump.build_quest("Alpha", %{})]
      test_pid = self()

      result =
        Dump.run(quests,
          fetch: fn _q -> {:ok, raw_sections()} end,
          resolve: fn _titles ->
            send(test_pid, :resolve_called)
            %{}
          end,
          write: recording_writer(),
          dry_run: true
        )

      assert result.summary == %{processed: 1, failed: 0, skipped: 0, resolved: 0}
      assert_received {:wrote, "alpha", _manifest}
      refute_received :resolve_called
    end

    test "suppresses the erroneous guide image for the Immunity quest, keeping the prose" do
      index = Dump.build_db_index([%{id: "i", name: "Immunity", normalized_name: "immunity"}])
      immunity = Dump.build_quest("Immunity (quest)", index)
      other = Dump.build_quest("Other", %{})
      test_pid = self()

      guide_wikitext =
        "==Guide==\nExtract while suffering from the " <>
          "[[File:Intoxication.png|46px|Unknown toxin]] effect.\n"

      sections = fn ->
        [
          %{
            index: "0",
            heading: "(lead / infobox)",
            level: "0",
            wikitext: "|given by =[[Therapist]]\n"
          },
          %{index: "4", heading: "Guide", level: "2", wikitext: guide_wikitext}
        ]
      end

      Dump.run([immunity, other],
        fetch: fn _q -> {:ok, sections.()} end,
        resolve: fn titles -> Map.new(titles, &{&1, %{"url" => "https://cdn/x"}}) end,
        write: fn quest, manifest ->
          send(test_pid, {:wrote, quest.normalized_name, manifest}) && :ok
        end
      )

      assert_received {:wrote, "immunity", immunity_manifest}
      guide = Enum.find(immunity_manifest.sections, &(&1.slug == "guide"))
      # Image gone (no resolved file, no inline ref in the stored wikitext)...
      assert guide.files == []
      refute guide.wikitext =~ "[[File:"
      # ...but the guide description survives.
      assert guide.wikitext =~ "Extract while suffering from the"
      assert guide.wikitext =~ "effect."
      assert immunity_manifest.summary.total_files == 0

      # A different quest with the same guide keeps its image.
      assert_received {:wrote, "other", other_manifest}
      other_guide = Enum.find(other_manifest.sections, &(&1.slug == "guide"))
      assert [%{wiki_filename: "Intoxication.png"}] = other_guide.files
    end
  end
end
