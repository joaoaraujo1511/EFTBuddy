defmodule EftBuddy.Chapters.SyncFetchPlanTest do
  @moduledoc """
  The order a chapter's sections are fetched in — which is the order they
  are stored in, and therefore the order they render in.

  "The Ticket" transcludes four complete branch walkthroughs inside its
  `==Guide==` section, ahead of the closing steps every ending shares.
  MediaWiki reports those as `T-N` slices carrying a `fromtitle`, and they
  cannot be fetched by index — so each template is fetched as a whole page,
  once, IN PLACE. Fetching the page's own sections first and appending the
  templates afterwards is what stranded the entire walkthrough at the foot
  of the page, below the endings, under a "Guide" heading that introduced
  four ending icons and nothing else.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Chapters.Sync

  defp own(index), do: %{index: index, heading: "Section #{index}", level: "2", fromtitle: nil}

  defp slice(index, template),
    do: %{index: index, heading: "Step", level: "3", fromtitle: template}

  describe "fetch_plan/1" do
    test "a page with no transclusions plans one fetch per section, in order" do
      assert Sync.fetch_plan([own("1"), own("2"), own("3")]) ==
               [{:own, own("1")}, {:own, own("2")}, {:own, own("3")}]
    end

    test "a transcluded template is fetched where the page puts it, not at the end" do
      plan =
        Sync.fetch_plan([
          own("8"),
          slice("T-1", "Template:The_Ticket_Section_Savior_Guide"),
          slice("T-2", "Template:The_Ticket_Section_Savior_Guide"),
          slice("T-1", "Template:The_Ticket_Section_Debtor_Guide"),
          own("9"),
          own("10")
        ])

      assert plan == [
               {:own, own("8")},
               {:template, "Template:The_Ticket_Section_Savior_Guide"},
               {:template, "Template:The_Ticket_Section_Debtor_Guide"},
               {:own, own("9")},
               {:own, own("10")}
             ]
    end

    test "each template is fetched once however many slices it reports" do
      slices = Enum.map(1..99, &slice("T-#{&1}", "Template:Savior"))

      assert Sync.fetch_plan(slices) == [{:template, "Template:Savior"}]
    end

    test "a slice with no fromtitle is unfetchable and dropped" do
      assert Sync.fetch_plan([own("1"), slice("T-1", nil)]) == [{:own, own("1")}]
    end

    test "an empty section list plans nothing" do
      assert Sync.fetch_plan([]) == []
    end
  end
end
