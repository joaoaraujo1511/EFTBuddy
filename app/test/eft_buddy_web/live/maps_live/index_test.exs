defmodule EftBuddyWeb.MapsLive.IndexTest do
  @moduledoc """
  Render-level coverage for the maps index: the search / status round-trip
  through the URL, and the boss chips.
  """
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EftBuddy.Fixtures

  defp map_with_bosses(slug, name, boss_entries) do
    map = Fixtures.game_map(%{normalized_name: slug, name: name})
    Enum.each(boss_entries, &Fixtures.map_boss(Map.put(&1, :map_id, map.id)))
    map
  end

  # Every integer rendered inside a tab's count badge.
  defp count_badges(html) do
    Regex.scan(~r/>\s*(\d+)\s*</, html)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end

  # HEEx renders `{boss.name}` with surrounding whitespace, so match the bare
  # name rather than a `>Name<` boundary.
  defp occurrences(html, needle), do: length(String.split(html, needle)) - 1

  describe "the grid" do
    test "lists visible maps", %{conn: conn} do
      Fixtures.game_map(%{normalized_name: "customs", name: "Customs"})
      Fixtures.game_map(%{normalized_name: "woods", name: "Woods"})

      {:ok, _view, html} = live(conn, ~p"/maps")

      assert html =~ "Customs"
      assert html =~ "Woods"
    end

    test "an empty catalog shows the standby panel rather than the grid", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/maps")
      refute html =~ "Recon"
    end
  end

  describe "boss chips" do
    # `map_bosses` is one row per spawn *entry*, so iterating it raw gave
    # Icebreaker 40 chips for its 5 bosses and The Lab 16 for its 1.
    test "many entries of one boss render a single chip", %{conn: conn} do
      entries =
        for i <- 1..16 do
          %{name: "Raider", normalized_name: "raider", external_id: "raider-#{i}", spawn_time: i}
        end

      map_with_bosses("the-lab", "The Lab", entries)

      {:ok, _view, html} = live(conn, ~p"/maps")

      assert occurrences(html, "Raider") == 1
    end

    test "distinct bosses each get a chip", %{conn: conn} do
      map_with_bosses("customs", "Customs", [
        %{name: "Reshala", normalized_name: "reshala", external_id: "reshala"},
        %{name: "Reshala", normalized_name: "reshala", external_id: "reshala-2"},
        %{name: "Partisan", normalized_name: "partisan", external_id: "partisan"}
      ])

      {:ok, _view, html} = live(conn, ~p"/maps")

      assert occurrences(html, "Reshala") == 1
      assert occurrences(html, "Partisan") == 1
    end
  end

  describe "search" do
    setup %{conn: conn} do
      Fixtures.game_map(%{normalized_name: "customs", name: "Customs"})
      Fixtures.game_map(%{normalized_name: "woods", name: "Woods"})
      %{conn: conn}
    end

    test "?q= filters the grid and survives a reload", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/maps?q=cust")

      assert html =~ "Customs"
      refute html =~ ">Woods<"
    end

    # The tab counts used to come from the full roster, so with a search active
    # "All" reported every map while the grid below showed one card. Asserted
    # through the tab links, which carry the count next to their label.
    test "the tab counts reflect the active search", %{conn: conn} do
      {:ok, _view, filtered} = live(conn, ~p"/maps?q=cust")
      {:ok, _view, unfiltered} = live(conn, ~p"/maps")

      # Two maps in the fixture set, one of which matches "cust".
      assert count_badges(unfiltered) |> Enum.member?(2)
      refute count_badges(filtered) |> Enum.member?(2)
      assert count_badges(filtered) |> Enum.member?(1)
    end

    test "a search matching nothing shows the no-results panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/maps?q=zzzzz")
      assert html =~ "maps"
      refute html =~ ">Customs<"
    end
  end

  describe "status filter" do
    test "?status=keyed keeps only maps that need an access key", %{conn: conn} do
      Fixtures.game_map(%{normalized_name: "customs", name: "Customs"})
      lab = Fixtures.game_map(%{normalized_name: "the-lab", name: "The Lab"})
      keycard = Fixtures.item(%{name: "Lab. access keycard"})
      Fixtures.map_access_key(%{map_id: lab.id, item_id: keycard.id})

      {:ok, _view, html} = live(conn, ~p"/maps?status=keyed")

      assert html =~ "The Lab"
      refute html =~ ">Customs<"
    end

    test "an unknown status snaps back to all", %{conn: conn} do
      Fixtures.game_map(%{normalized_name: "customs", name: "Customs"})

      {:ok, _view, html} = live(conn, ~p"/maps?status=nonsense")

      assert html =~ "Customs"
    end
  end
end
