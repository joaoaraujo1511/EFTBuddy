defmodule EftBuddy.Items.Sync.Resolvers do
  @moduledoc """
  The lookup maps every items-family sync builds before it can write anything,
  plus the small coercions their row builders share.

  tarkov.dev identifies everything by its own opaque string id, and every table
  here keys on a local UUID — so each sync's first act is to load a
  `%{external_id => uuid}` map for whatever it is about to reference. Barters
  need items, traders and tasks; crafts need items, station levels and tasks;
  the price passes need items. Those queries were private to one 2,300-line
  module while all of that work lived in it.

  They are here rather than duplicated per module because a second copy of
  `fetch_item_map/1` that quietly diverged — a missing `where`, a different
  key — would produce a sync that resolves *most* of its foreign keys and
  silently drops the rest. That is the failure mode this whole family is
  hardest to notice.

  Nothing here writes. Every function takes an explicit `repo` so it can run
  inside an `Ecto.Multi`.
  """

  import Ecto.Query

  alias EftBuddy.Hideout.{Station, StationLevel, Trader}
  alias EftBuddy.Items.{Barter, Category, Craft, Item, Vendor}
  alias EftBuddy.Tasks.Task, as: TaskRow

  @doc "`%{external_id => item_id}` for the whole catalogue."
  def item_map(repo) do
    from(i in Item, select: {i.external_id, i.id})
    |> repo.all()
    |> Map.new()
  end

  @doc "`%{external_id => category_id}`."
  def category_map(repo) do
    from(c in Category, select: {c.external_id, c.id})
    |> repo.all()
    |> Map.new()
  end

  @doc "`%{vendor_name => vendor_id}`."
  def vendor_map(repo) do
    from(v in Vendor, select: {v.name, v.id})
    |> repo.all()
    |> Map.new()
  end

  @doc """
  `%{normalized_name => trader_id}`.

  Populated by two feeds between them: the hideout sync writes most traders, and
  the task sync contributes Ref, Fence and Lightkeeper, which appear in no
  hideout data but are referenced by barters.
  """
  def trader_map(repo) do
    from(t in Trader, select: {t.normalized_name, t.id})
    |> repo.all()
    |> Map.new()
  end

  @doc "`%{external_id => task_id}` for one game mode."
  def task_map(repo, game_mode) do
    from(t in TaskRow, where: t.game_mode == ^game_mode, select: {t.external_id, t.id})
    |> repo.all()
    |> Map.new()
  end

  @doc """
  `%{{station_slug, level} => station_level_id}`.

  Lets crafts resolve onto the existing hideout schema instead of duplicating
  station and level columns.
  """
  def station_level_map(repo) do
    from(l in StationLevel,
      join: s in Station,
      on: s.id == l.station_id,
      select: {{s.normalized_name, l.level}, l.id}
    )
    |> repo.all()
    |> Map.new()
  end

  @doc """
  `%{external_id => barter_id}` for one game mode.

  **Scoped to the mode on purpose.** The two modes' barter external_id sets are
  disjoint, so an unscoped map would still resolve every child lookup — but it is
  also handed to `EftBuddy.Items.Sync.Children.replace_children/5`, whose delete
  step wipes the children of *every* parent id in the map. Unscoped, the second
  mode's pass deleted the first mode's barter reward and required rows, which
  surfaced as an empty Barter tab in whichever mode synced first.
  """
  def barter_id_map(repo, game_mode) do
    from(b in Barter, where: b.game_mode == ^game_mode, select: {b.external_id, b.id})
    |> repo.all()
    |> Map.new()
  end

  @doc "`%{external_id => craft_id}`. Crafts are identical across modes."
  def craft_id_map(repo) do
    from(c in Craft, select: {c.external_id, c.id})
    |> repo.all()
    |> Map.new()
  end

  @doc """
  Whether every entry in `list` names an item present in `items_map`.

  A barter or craft is written whole or not at all: a recipe missing one
  ingredient is worse than a missing recipe, because it renders as a complete
  answer.
  """
  def all_items_resolvable?(list, items_map) do
    Enum.all?(list, fn
      %{"item" => %{"id" => id}} -> Map.has_key?(items_map, id)
      _ -> false
    end)
  end

  @doc "The local task id a `taskUnlock` payload refers to, or nil."
  def resolve_task_unlock(nil, _tasks_map), do: nil
  def resolve_task_unlock(%{"id" => id}, tasks_map), do: Map.get(tasks_map, id)
  def resolve_task_unlock(_other, _tasks_map), do: nil

  @doc """
  Coerce a count to a positive integer, or nil.

  The API types `count` and `quantity` as `Float!` while these columns are
  integers — for barters and crafts they are always whole numbers in practice.
  Anything non-numeric becomes nil and is filtered out by the caller.
  """
  def trunc_or_nil(nil), do: nil
  def trunc_or_nil(n) when is_integer(n) and n > 0, do: n
  def trunc_or_nil(n) when is_float(n) and n > 0.0, do: trunc(n)
  def trunc_or_nil(_other), do: nil

  @doc """
  Flatten `[%{"name" => _, "value" => _}]` into a plain map.

  Duplicate names take the last value, which is acceptable for display-only
  metadata.
  """
  def encode_attributes(nil), do: %{}

  def encode_attributes(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) -> Map.put(acc, name, value)
      _entry, acc -> acc
    end)
  end

  def encode_attributes(_other), do: %{}
end
