defmodule EftBuddy.Ammo do
  @moduledoc """
  The Ammo context: the ballistics catalog behind the `/ammo` page.

  Rounds are synced into the `ammo` table by `EftBuddy.Ammo.Sync` (from
  the tarkov.dev items `properties` fragment). Each round links back to
  its `items` row for the display name / icon and for **availability** —
  which is derived here, not stored:

    * `"trader"` — the round has a cash trader offer (`buy_for` from a
      trader vendor)
    * `"flea"`   — it has a Flea Market `buy_for` offer
    * `"barter"` — it's the reward of a trader barter
    * `"craft"`  — it's the output of a hideout craft

  Availability is read for the default (`regular`) game mode only:
  ballistics are identical across PVP/PVE, so the page is a single,
  mode-agnostic view.

  `list_rounds/0` does the DB work (rounds + the four availability sets)
  once; the pure `filter/2`, `group/2` and `source_counts/2` helpers then
  slice that list for the LiveView without further queries.
  """

  import Ecto.Query

  alias EftBuddy.Ammo.{Caliber, Round}
  alias EftBuddy.Cache
  alias EftBuddy.Items.{BarterRewardItem, BuyFor, CraftRewardItem}
  alias EftBuddy.Repo
  alias EftBuddy.Sortable

  # The synthetic Flea Market vendor slug (see `TarkovApi` / `Items.Sync`).
  @flea_slug "flea-market"

  # Availability source tokens, in display order.
  @sources ~w(trader flea barter craft)

  # col → schema field for sorting. Declared here so the page's sortable
  # columns are defined in one place.
  @sort_columns %{
    "name" => :name,
    "damage" => :damage,
    "pen" => :penetration_power,
    "armor" => :armor_damage,
    "pen_chance" => :penetration_chance,
    "ricochet" => :ricochet_chance,
    "accuracy" => :accuracy_modifier,
    "recoil" => :recoil_modifier,
    "velocity" => :initial_speed,
    "light_bleed" => :light_bleed_modifier,
    "heavy_bleed" => :heavy_bleed_modifier,
    "stack" => :stack_max_size
  }

  # Force the `:<col>_asc` / `:<col>_desc` atoms into existence at compile
  # time so `EftBuddyWeb.UI.next_sort/2`'s `String.to_existing_atom/1`
  # lookup always resolves them (never falls back to `:default` for a
  # legitimate column click).
  @sort_atoms Sortable.atoms(Map.keys(@sort_columns))

  @doc "The availability source tokens, in display order."
  def sources, do: @sources

  @doc "The sortable column keys (the `col` values `sort_header/1` emits)."
  def sort_columns, do: Map.keys(@sort_columns)

  @doc false
  def sort_atoms, do: @sort_atoms

  # Ballistics change on a game patch; the item rows they hang off change with
  # the catalog. Both are daily-ish feeds.
  @ballistics_sources ["AmmoSync", "ItemsSync"]

  # Availability is derived from `buy_for` rows, which `PricesSync` rewrites
  # every ten minutes, plus the barter and craft reward tables. ItemsSync is in
  # here too because deleting an item cascades its `buy_for` rows away.
  @availability_sources ["ItemsSync", "PricesSync", "BartersSync", "CraftsSync"]

  @doc """
  Every ammo round, each with its `:item` preloaded and its `:sources`
  virtual field populated (a list of the availability tokens above).

  Bounded to the ~200 rounds in the game, so the LiveView holds the result
  and derives its filtered views from it without re-querying on every
  keystroke.

  ## Why this is two caches and not one

  This is the app's single most expensive read — six queries and ~1,470ms
  against a database 75ms away — and it is built from two things with wildly
  different lifetimes.

  The ballistics half changes on a game patch. The availability half is derived
  from `buy_for`, which the flea price refresh rewrites **every ten minutes**.
  Caching the stitched result under the union of both would therefore throw away
  the expensive half six times an hour to pick up a change in the cheap one — a
  cache that spends most of its life cold, on the one read that can least afford
  it.

  Split, the ten-minute tick invalidates four small `SELECT DISTINCT` sets and
  the round set survives until the game actually patches. The stitch itself is
  pure and costs microseconds over 200 rounds, so it is deliberately NOT cached:
  a third entry would need the union of both source lists and reintroduce
  exactly the coupling this split removes.
  """
  def list_rounds do
    rounds = ballistics()
    %{trader: trader, flea: flea, barter: barter, craft: craft} = availability()

    Enum.map(rounds, fn round ->
      %{round | sources: sources_for(round.item_id, trader, flea, barter, craft)}
    end)
  end

  @doc false
  # The stable half: the rounds and their linked item rows.
  def ballistics do
    Cache.fetch({__MODULE__, :ballistics}, @ballistics_sources, fn ->
      Round |> preload(:item) |> Repo.all()
    end)
  end

  @doc false
  # The volatile half: four sets of item ids, rebuilt on every price refresh.
  def availability do
    Cache.fetch({__MODULE__, :availability}, @availability_sources, fn ->
      %{
        trader: buy_item_ids(:trader),
        flea: buy_item_ids(:flea),
        barter: reward_item_ids(BarterRewardItem),
        craft: reward_item_ids(CraftRewardItem)
      }
    end)
  end

  defp sources_for(nil, _trader, _flea, _barter, _craft), do: []

  defp sources_for(item_id, trader, flea, barter, craft) do
    [{"trader", trader}, {"flea", flea}, {"barter", barter}, {"craft", craft}]
    |> Enum.filter(fn {_token, set} -> MapSet.member?(set, item_id) end)
    |> Enum.map(&elem(&1, 0))
  end

  # Distinct item ids buyable for the default mode, split by whether the
  # vendor is the Flea Market or a real trader.
  defp buy_item_ids(which) do
    mode = EftBuddy.GameMode.default()

    base =
      from(b in BuyFor,
        join: v in assoc(b, :vendor),
        where: b.game_mode == ^mode,
        select: b.item_id,
        distinct: true
      )

    query =
      case which do
        :flea -> where(base, [b, v], v.normalized_name == @flea_slug)
        :trader -> where(base, [b, v], v.normalized_name != @flea_slug)
      end

    query |> Repo.all() |> MapSet.new()
  end

  # Distinct item ids that are the reward/output of a barter or craft.
  # Mode-agnostic (single availability view): a round obtainable by
  # barter in either mode counts as barterable.
  defp reward_item_ids(schema) do
    from(r in schema, select: r.item_id, distinct: true)
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Pure list helpers (operate on the list_rounds/0 result) ──────────

  @doc """
  The distinct calibers present in `rounds`, in curated display order, as
  `{caliber_enum, label}` tuples — backs the caliber filter chips.
  """
  def calibers_present(rounds) do
    rounds
    |> Enum.map(& &1.caliber)
    |> Enum.uniq()
    |> Enum.sort_by(&{Caliber.order(&1), Caliber.label(&1)})
    |> Enum.map(&{&1, Caliber.label(&1)})
  end

  @doc """
  Filter `rounds` by a free-text `query` (name or caliber label),
  `caliber` (`"all"` or a raw enum) and `source` (`"all"` or one of the
  source tokens). Opts is a map with string-ish values from the LiveView.
  """
  def filter(rounds, opts) do
    query = opts |> Map.get(:query, "") |> to_string() |> String.trim() |> String.downcase()
    caliber = Map.get(opts, :caliber, "all")
    source = Map.get(opts, :source, "all")

    rounds
    |> Enum.filter(&caliber_match?(&1, caliber))
    |> Enum.filter(&source_match?(&1, source))
    |> Enum.filter(&search_match?(&1, query))
  end

  defp caliber_match?(_round, "all"), do: true
  defp caliber_match?(round, caliber), do: round.caliber == caliber

  defp source_match?(_round, "all"), do: true
  defp source_match?(round, source), do: source in round.sources

  defp search_match?(_round, ""), do: true

  defp search_match?(round, needle) do
    name = round.item && round.item.name
    label = Caliber.label(round.caliber)

    (is_binary(name) and String.contains?(String.downcase(name), needle)) or
      String.contains?(String.downcase(label), needle)
  end

  @doc """
  Group `rounds` by caliber and sort **within each group** by `sort`,
  returning `[{caliber_enum, label, sorted_rounds}]` in caliber display
  order (empty groups dropped).

  The sort is scoped per block: the caliber order of the page never
  changes, only the ordering of rounds inside each caliber section.
  `sort` is a `:<col>_asc` / `:<col>_desc` atom (or `:default`, which
  sorts by penetration power descending).
  """
  def group(rounds, sort \\ :default)

  # Per-block sort: `sorts` maps a caliber enum to its own sort atom, so
  # each caliber section on the page sorts independently. Calibers absent
  # from the map fall back to `:default`.
  def group(rounds, sorts) when is_map(sorts) do
    group_and_sort(rounds, fn caliber -> Map.get(sorts, caliber, :default) end)
  end

  # Uniform sort: every block sorted the same way.
  def group(rounds, sort) do
    group_and_sort(rounds, fn _caliber -> sort end)
  end

  defp group_and_sort(rounds, sort_for) do
    rounds
    |> Enum.group_by(& &1.caliber)
    |> Enum.map(fn {caliber, group_rounds} ->
      {caliber, Caliber.label(caliber), sort_rounds(group_rounds, sort_for.(caliber))}
    end)
    |> Enum.sort_by(fn {caliber, label, _} -> {Caliber.order(caliber), label} end)
  end

  # Sort a caliber block. `:default` (the unsorted state) puts the strongest
  # round first — penetration power descending, the "best round up top"
  # ordering the ballistics chart wants; any other atom sorts by its column.
  defp sort_rounds(rounds, sort) do
    case Sortable.resolve(sort, @sort_columns) do
      {:default, _dir} -> Enum.sort_by(rounds, & &1.penetration_power, :desc)
      {field, dir} -> Enum.sort_by(rounds, &sort_value(&1, field), dir)
    end
  end

  defp sort_value(round, :name), do: round.item && round.item.name
  defp sort_value(round, field), do: Map.get(round, field)

  @doc """
  Per-source counts honoring the current `query` + `caliber` context (but
  not the active source), so the availability tab badges always match what
  each tab reveals. Returns `%{"all" => n, "trader" => n, ...}`.
  """
  def source_counts(rounds, opts) do
    base =
      filter(rounds, %{
        query: Map.get(opts, :query, ""),
        caliber: Map.get(opts, :caliber, "all"),
        source: "all"
      })

    counts =
      Map.new(@sources, fn source ->
        {source, Enum.count(base, &(source in &1.sources))}
      end)

    Map.put(counts, "all", length(base))
  end
end
