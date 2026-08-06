defmodule EftBuddy.Items do
  @moduledoc """
  The Items context. Manages items, categories, vendors, and their relationships.
  """

  import Ecto.Query

  require Logger

  alias EftBuddy.Hideout.ItemRequirement, as: HideoutItemRequirement
  # Only the *RequiredItem / *RewardItem schemas are referenced by
  # name here — the bare `Craft` / `Barter` modules are reached via
  # `assoc(rw, :barter)` / `assoc(rw, :craft)` joins, which don't
  # need an explicit alias.
  alias EftBuddy.Items.{BarterRequiredItem, BarterRewardItem}
  alias EftBuddy.Items.{CraftRequiredItem, CraftRewardItem}
  alias EftBuddy.Items.{Item, ItemPrice}
  alias EftBuddy.Cache
  # The in-memory catalogue these three listing reads prefer when it is built and
  # fresh. `ready?/1` is the whole safety story: it is false before the first
  # build, during a rebuild and past a staleness bound, and every one of those
  # falls through to the SQL below. The dataset can therefore be absent, stale or
  # switched off without any of this returning a wrong answer — only a slower one.
  alias EftBuddy.Items.Dataset
  alias EftBuddy.Repo
  alias EftBuddy.Tasks.{ItemReward, Objective, OfferUnlock}

  # Tasks whose payload data is misleading or wrong relative to
  # what the user actually has to do. Blacklisted by exact name
  # so:
  #
  #   * the per-item "Needed by quests" list never mentions them,
  #   * the "Quest items" scope filter doesn't surface items that
  #     are *only* referenced by these tasks (which would otherwise
  #     pollute the tab with hundreds of keys / build flags).
  #
  # Verified against the live API:
  #
  #   * "Key Partner" — payload lists every key as a quest item,
  #     but in practice the user only needs to *find* one of them.
  #   * "Building Foundations" — same pattern: payload lists every
  #     building-material flag the task can accept.
  #   * "Circulate" — payload lists every barter currency the task
  #     can rotate through, surfacing dozens of items the user does
  #     not need to actively grind. Same fix shape as the other two.
  #
  # Sourced from config (`:eft_buddy, :task_objective_blacklist`) so
  # the list can be tuned per environment without a code change; the
  # default below is baked at compile time. If the API ever fixes
  # these, removing the entry (here or in config) is enough.
  @task_name_blacklist Application.compile_env(
                         :eft_buddy,
                         :task_objective_blacklist,
                         ["Key Partner", "Building Foundations", "Circulate"]
                       )

  # ── Items ──────────────────────────────────────────────

  @doc """
  Resolve a list of wiki "Related Quest Items" page names to the real
  items synced from tarkov.dev. Returns a `%{page => item}` map
  containing ONLY the names backed by an actual item.

  Wiki tables sometimes list category/concept links ("building
  materials", "weapons", …) that aren't real items; those simply won't
  appear in the result, so callers treat their absence as "not an item"
  (render plain text, no link/image). Matching tries the tarkov.dev
  `normalized_name` slug first (which also reconciles the wiki's
  `#`/punctuation differences) and falls back to a case-insensitive
  exact name match.
  """
  def resolve_wiki_items(pages) when is_list(pages) do
    pages = pages |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    slugs = Enum.map(pages, &wiki_name_slug/1)
    lowered = Enum.map(pages, &(&1 |> String.trim() |> String.downcase()))

    items =
      Item
      |> where([i], i.normalized_name in ^slugs or fragment("lower(?)", i.name) in ^lowered)
      |> Repo.all()

    by_slug = Map.new(items, &{&1.normalized_name, &1})
    by_name = Map.new(items, &{String.downcase(&1.name), &1})

    pages
    |> Enum.flat_map(fn page ->
      case Map.get(by_slug, wiki_name_slug(page)) ||
             Map.get(by_name, page |> String.trim() |> String.downcase()) do
        nil -> []
        item -> [{page, item}]
      end
    end)
    |> Map.new()
  end

  # Lowercase, dash-joined slug matching tarkov.dev's `normalizedName`.
  defp wiki_name_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Paginated, searchable listing of every item in the catalog.

  Unlike `list_flea_market_items/1` this does NOT require a flea price —
  it returns every row in the `items` table so the Items tab can act as
  the full game catalog.

  Options:
    :limit – page size (default 40)
    :offset – number of rows to skip (default 0)
    :query – free-text search; matches against `name` and `short_name`
             using AND-of-tokens.
    :sort – `:default` (A→Z by designation, same as `:name_asc`),
            `:name_asc` / `:name_desc` by designation, or `:class_asc` /
            `:class_desc` by category (class) name.
    :scope – `:all` (default), `:hideout` (only items required by at
             least one hideout station level), or `:quest` (only items
             that any task objective references — either as a
             turn-in / find target via `payload.items`, or as a
             required key via `payload.required_key_ids`). The Items
             tab uses this to let the user toggle between "every
             item" and the practical "what do I still need to
             grind" subsets.
  """
  def list_all_items(opts \\ []) do
    if Dataset.ready?(Keyword.get(opts, :game_mode)) do
      Dataset.list_all_items(opts)
    else
      list_all_items_sql(opts)
    end
  end

  defp list_all_items_sql(opts) do
    limit = Keyword.get(opts, :limit, 40)
    offset = Keyword.get(opts, :offset, 0)
    query = opts |> Keyword.get(:query, "") |> normalize_query()
    sort = Keyword.get(opts, :sort, :default)
    scope = Keyword.get(opts, :scope, :all)
    category_names = Keyword.get(opts, :category_names, [])
    game_mode = opts |> Keyword.get(:game_mode) |> EftBuddy.GameMode.to_db()
    favorite_slugs = Keyword.get(opts, :favorite_slugs, [])

    Item
    |> join(:left, [i], c in assoc(i, :category), as: :category)
    |> apply_item_scope(scope, favorite_slugs, game_mode)
    |> apply_search(query)
    |> apply_category_names(category_names)
    |> with_mode_prices(game_mode)
    |> apply_favorites_first(scope, favorite_slugs)
    |> apply_items_sort(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:category)
    |> select_merge_mode_prices()
    |> Repo.all()
  end

  # `:watchlist` isn't a catalog subset like the structured scopes — it cuts
  # across every category, narrowing the listing to the operator's favourited
  # slugs (matched on the stable `normalized_name`). Routed here so the
  # `apply_scope/2` chain stays focused on the structured scopes. Reuses the
  # same `apply_favorites/2` the flea listing uses.
  defp apply_item_scope(query, :watchlist, favorite_slugs, _game_mode),
    do: apply_favorites(query, favorite_slugs)

  defp apply_item_scope(query, scope, _favorite_slugs, game_mode),
    do: apply_scope(query, scope, game_mode)

  # Float watchlisted items to the very top of every NON-watchlist listing (on
  # the watchlist scope everything is a favourite, so ordering there is moot).
  # `slug = ANY($slugs)` is a Postgres boolean — TRUE for favourites — and
  # `DESC` sorts TRUE first; the regular name/price sort appended afterwards
  # breaks ties within each group. An empty watchlist is a no-op.
  defp apply_favorites_first(query, :watchlist, _slugs), do: query

  defp apply_favorites_first(query, _scope, slugs) do
    case Enum.filter(slugs, &(is_binary(&1) and &1 != "")) do
      [] -> query
      cleaned -> order_by(query, [i], desc: fragment("? = ANY(?)", i.normalized_name, ^cleaned))
    end
  end

  @doc """
  Item counts per Items-page scope tab (`:all`, `:hideout`, `:quest`,
  `:barter`, `:craft`), so the tabs can show "ALL ITEMS (N)". Each is a
  `COUNT(*)` over the same scope filter the listing uses, so the badge
  always matches what the tab reveals.

  Mode-aware: the `:quest` and `:barter` scopes filter on the active
  game mode (their underlying tasks / barters carry a `game_mode`), so
  the tab counts track the operator's PVP/PVE toggle and never mark an
  item as barterable/quest-relevant in a mode where it has no data. The
  `:hideout` and `:craft` scopes are mode-independent (those tables have
  no `game_mode`), so they return the same count in both modes.
  """
  def scope_counts(game_mode \\ EftBuddy.GameMode.default()) do
    Cache.fetch({__MODULE__, :scope_counts, game_mode}, ["ItemsSync"], fn ->
      scope_counts_uncached(game_mode)
    end)
  end

  defp scope_counts_uncached(game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    Map.new([:all, :hideout, :quest, :barter, :craft], fn scope ->
      count =
        Item
        |> apply_scope(scope, mode)
        |> Repo.aggregate(:count)

      {scope, count}
    end)
  end

  # Category tokens a per-row pill can render, in display order. Kept
  # as a module attr so `category_flags_for/2` and any UI helper agree
  # on the vocabulary.
  @category_tokens [
    :needed_for_quests,
    :obtained_from_quests,
    :obtained_from_barters,
    :needed_for_barters,
    :obtained_from_crafts,
    :needed_for_crafts,
    :needed_for_hideout
  ]

  @doc "The category tokens surfaced as per-item pills, in display order."
  def category_tokens, do: @category_tokens

  @doc """
  Batch-compute, for a page of `item_ids`, which "availability"
  categories each item qualifies for — powering the coloured pills the
  Items list renders next to every item name (mirroring the Tasks
  page's Kappa/Lightkeeper badges).

  Returns a `%{item_id => [token, ...]}` map; item ids with no
  categories are still present with an empty list. Tokens are a subset
  of `category_tokens/0`:

    * `:needed_for_quests`     — referenced by a quest objective
      (turn-in / find target, required key, or quest-exclusive item).
    * `:obtained_from_quests`  — handed over as a quest reward.
    * `:obtained_from_barters` — the reward of a trader barter.
    * `:needed_for_barters`    — an input to a trader barter.
    * `:obtained_from_crafts`  — the output of a hideout craft.
    * `:needed_for_crafts`     — an input to a hideout craft.
    * `:needed_for_hideout`    — part of a hideout station build cost.

  Mode-aware where the underlying data is: the quest and barter tokens
  honor `game_mode` (their tasks / barters carry a `game_mode`), so the
  pills track the operator's PVP/PVE toggle and stay in lockstep with
  both the scope-tab counts and the per-item detail panel. Craft and
  hideout tokens are mode-independent (those tables have no
  `game_mode`).

  One small aggregate query per token over the given id set (each a
  `SELECT DISTINCT item_id ... WHERE item_id = ANY($ids)`), so the
  whole batch is a handful of round-trips regardless of page size and
  never grows with the catalog.
  """
  def category_flags_for(item_ids, game_mode \\ EftBuddy.GameMode.default())

  def category_flags_for([], _game_mode), do: %{}

  def category_flags_for(item_ids, game_mode) when is_list(item_ids) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    sets = %{
      needed_for_quests: quest_needed_ids(item_ids, mode),
      obtained_from_quests: quest_reward_ids(item_ids, mode),
      obtained_from_barters: barter_reward_ids(item_ids, mode),
      needed_for_barters: barter_required_ids(item_ids, mode),
      obtained_from_crafts: craft_reward_ids(item_ids),
      needed_for_crafts: craft_required_ids(item_ids),
      needed_for_hideout: hideout_required_ids(item_ids)
    }

    Map.new(item_ids, fn id ->
      tokens = for token <- @category_tokens, MapSet.member?(sets[token], id), do: token
      {id, tokens}
    end)
  end

  # Each helper returns a `MapSet` of the ids (from the given page)
  # that fall into its category. `id in ^item_ids` keeps the scan
  # bounded to the visible page.
  # Filter through the real `items.id` (a `binary_id`) rather than the
  # union's fragment-derived `uuid` column. Comparing the page's string
  # UUIDs against `items.id` lets Ecto dump them to the 16-byte binaries
  # Postgrex expects; the union membership stays SQL-side (`id IN
  # (subquery)`), exactly like the `:quest` scope. Comparing the string
  # list directly against the fragment `uuid` column instead raises
  # "Postgrex expected a binary of 16 bytes" (Ecto can't infer the
  # dump type for a fragment-derived column).
  defp quest_needed_ids(item_ids, mode) do
    uuid_subq = from(u in subquery(quest_item_union(mode)), select: u.uuid)

    from(i in Item,
      where: i.id in ^item_ids and i.id in subquery(uuid_subq),
      select: i.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp quest_reward_ids(item_ids, mode) do
    from(r in ItemReward,
      join: t in assoc(r, :task),
      where: r.item_id in ^item_ids and t.game_mode == ^mode,
      distinct: true,
      select: r.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp barter_reward_ids(item_ids, mode) do
    from(rw in BarterRewardItem,
      join: b in assoc(rw, :barter),
      where: rw.item_id in ^item_ids and b.game_mode == ^mode,
      distinct: true,
      select: rw.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp barter_required_ids(item_ids, mode) do
    from(rq in BarterRequiredItem,
      join: b in assoc(rq, :barter),
      where: rq.item_id in ^item_ids and b.game_mode == ^mode,
      distinct: true,
      select: rq.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp craft_reward_ids(item_ids) do
    from(rw in CraftRewardItem,
      where: rw.item_id in ^item_ids,
      distinct: true,
      select: rw.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp craft_required_ids(item_ids) do
    from(rq in CraftRequiredItem,
      where: rq.item_id in ^item_ids,
      distinct: true,
      select: rq.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp hideout_required_ids(item_ids) do
    from(r in HideoutItemRequirement,
      where: r.item_id in ^item_ids,
      distinct: true,
      select: r.item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Scope filter ───────────────────────────────────────

  # `:hideout` – item appears in at least one hideout build cost.
  # `:quest`   – item appears in the `payload->'items'` array, the
  #              `payload->'required_key_ids'` array, OR the scalar
  #              `payload->>'questItem'` field of at least one task
  #              objective. The first two store items as JSON arrays
  #              of stringified UUIDs (resolved at sync time); the
  #              third is a single stringified UUID. We project all
  #              three onto a uuid column we can union and join on.
  defp apply_scope(query, :all, _game_mode), do: query

  # Hideout build costs have no game_mode (the stash is shared across
  # PVP/PVE), so this scope is mode-independent.
  defp apply_scope(query, :hideout, _game_mode) do
    item_ids_subq =
      from(r in HideoutItemRequirement, distinct: true, select: r.item_id)

    where(query, [i], i.id in subquery(item_ids_subq))
  end

  defp apply_scope(query, :quest, game_mode) do
    # The union yields every distinct item_id referenced by any
    # (non-blacklisted) objective for the active mode — turn-in /
    # find targets (`payload->'items'`), required keys
    # (`payload->'required_key_ids'`) and quest-exclusive items
    # (`payload->>'questItem'`). See `quest_item_union/1` for the
    # per-arm rationale. Mode-scoped so the Quest Items tab tracks
    # the PVP/PVE toggle (tasks carry a `game_mode`).
    #
    # `quest_item_union/1` selects a `%{uuid: ...}` map (so it can
    # also be filtered/aliased by the per-page category-flag batch),
    # so we re-select the bare `uuid` column here to keep the
    # `IN (subquery)` a single-column membership test.
    uuid_subq = from(u in subquery(quest_item_union(game_mode)), select: u.uuid)

    where(query, [i], i.id in subquery(uuid_subq))
  end

  # `:barter` – item is *involved* in at least one trader barter,
  #             whether as a reward (the item can be obtained via
  #             barter) or as an input (the item can be spent as
  #             part of a barter cost). The previous version only
  #             matched rewards, so items like RAM stick — which
  #             is never a barter reward but is required by
  #             several trader barters — silently fell out of the
  #             tab even though their detail panel proudly listed
  #             "Needed for: <barter>" rows.
  # `:craft`  – item is involved in at least one hideout craft,
  #             same semantics: either side of the recipe (input
  #             or output) qualifies. Mirrors `:barter`.
  #
  # Both pivot on a UNION of the relevant `*RewardItem` and
  # `*RequiredItem` tables, selecting distinct `item_id`s,
  # mirroring how the `:hideout` scope queries
  # `HideoutItemRequirement`. We use `subquery/1` rather than
  # joining directly so the outer query stays a clean
  # `WHERE id IN (...)` — that lets the existing search / sort
  # passes compose without grappling with duplicate rows from a
  # one-to-many join. `union_all/2` is fine because the outer
  # `IN` dedupes for free; using it avoids Postgres' implicit
  # sort that `UNION` (distinct) would do.
  #
  # Both clauses also exclude items whose container has its own
  # reward row — e.g. ".300 Blackout CBJ" (the round) is hidden
  # when "Pack of .300 Blackout CBJ ammo" (the box that contains
  # it) also appears as a reward, because the API encodes some
  # ammo barters at both ids and the user perceives them as a
  # single barter showing twice. The `contains_item_id` column on
  # items is populated by
  # `EftBuddy.Items.Sync.set_contains_item_id/3`; for items
  # without a container (the vast majority) the `NOT IN`
  # subquery has no effect.
  #
  # The dedupe is now also gated on the contained item NOT
  # appearing in the *required* (input) set, so a round that's
  # legitimately an input to some unrelated barter/craft stays
  # visible. Without this gate, broadening the scope to inputs
  # would have re-introduced the round through the input path,
  # only for the dedupe to remove it again — a regression we'd
  # only notice as "this round is needed for X but doesn't show
  # up in BARTER ITEMS".
  #
  # MUST be declared *above* the catch-all `_` clause below so
  # Elixir's top-down clause matching reaches them before the
  # fallback swallows the call.
  # Barters carry a `game_mode`, so this scope is mode-scoped: an
  # item that's only bartered in the *other* mode must not be marked
  # barterable here (that mismatch is exactly what made the tab count
  # an item as barterable while its detail panel — which already
  # filters by mode — rendered nothing). Both reward and required
  # subqueries join through to the parent barter to filter on mode.
  defp apply_scope(query, :barter, game_mode) do
    reward_ids_subq =
      from(rw in BarterRewardItem,
        join: b in assoc(rw, :barter),
        where: b.game_mode == ^game_mode,
        distinct: true,
        select: rw.item_id
      )

    required_ids_subq =
      from(rq in BarterRequiredItem,
        join: b in assoc(rq, :barter),
        where: b.game_mode == ^game_mode,
        distinct: true,
        select: rq.item_id
      )

    involved_ids_subq = union_all(reward_ids_subq, ^required_ids_subq)

    contained_redundant_subq =
      from(box in Item,
        where: not is_nil(box.contains_item_id),
        where: box.id in subquery(reward_ids_subq),
        where: box.contains_item_id not in subquery(required_ids_subq),
        select: box.contains_item_id
      )

    query
    |> where([i], i.id in subquery(involved_ids_subq))
    |> where([i], i.id not in subquery(contained_redundant_subq))
  end

  # Crafts have no game_mode (hideout production is shared across
  # PVP/PVE), so this scope is mode-independent.
  defp apply_scope(query, :craft, _game_mode) do
    reward_ids_subq =
      from(rw in CraftRewardItem, distinct: true, select: rw.item_id)

    required_ids_subq =
      from(rq in CraftRequiredItem, distinct: true, select: rq.item_id)

    involved_ids_subq = union_all(reward_ids_subq, ^required_ids_subq)

    contained_redundant_subq =
      from(box in Item,
        where: not is_nil(box.contains_item_id),
        where: box.id in subquery(reward_ids_subq),
        where: box.contains_item_id not in subquery(required_ids_subq),
        select: box.contains_item_id
      )

    query
    |> where([i], i.id in subquery(involved_ids_subq))
    |> where([i], i.id not in subquery(contained_redundant_subq))
  end

  # Unknown scopes fall through to "show everything" rather than
  # silently returning zero rows.
  defp apply_scope(query, _, _game_mode), do: query

  # ── Projections for EftBuddy.Items.Dataset ─────────────
  #
  # These exist so the in-memory dataset can be built from the SAME predicates
  # and the SAME ordering the SQL path uses, rather than from a reimplementation
  # of them. That is the whole safety argument for the dataset layer, so it is
  # worth being explicit about why each one is a projection rather than a
  # reimplementation:
  #
  #   * `apply_scope/3` for `:quest` is a three-arm UNION over JSONB payload
  #     fields, with a task-name blacklist. Rewriting that in Elixir is the most
  #     likely place in this codebase to introduce a silent divergence, and a
  #     divergence here means the Quest Items tab quietly shows the wrong items.
  #     So Postgres computes the id set and the dataset merely holds it.
  #
  #   * Ordering is collation-dependent and CANNOT be reproduced by `Enum.sort/1`.
  #     Measured against production, the two disagree on the very first row:
  #     Postgres files `"Negotiation" room key` under N (its collation ignores
  #     leading punctuation) while byte order sorts it above `.300 Blackout AP`.
  #     So Postgres produces the order, once, and the dataset stores the
  #     resulting id list. Filtering an ordered list is stable, so every derived
  #     page keeps that order exactly.

  @doc false
  @spec ordered_ids(atom()) :: [binary()]
  def ordered_ids(sort) do
    Item
    |> join(:left, [i], c in assoc(i, :category), as: :category)
    |> apply_items_sort(sort)
    |> select([i], i.id)
    |> Repo.all()
  end

  @doc false
  @spec scope_ids(atom(), any()) :: [binary()]
  def scope_ids(scope, game_mode) do
    Item
    |> apply_scope(scope, EftBuddy.GameMode.to_db(game_mode))
    |> select([i], i.id)
    |> Repo.all()
  end

  @doc false
  # Flea-eligible items for a mode, already in the listing's price order. The
  # ordering is numeric rather than collated, so Elixir *could* reproduce it —
  # but it is taken from Postgres anyway, because "all ordering comes from one
  # place" is a property worth more than one saved query every ten minutes.
  @spec flea_ordered_ids(any()) :: [binary()]
  def flea_ordered_ids(game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    Item
    |> join(:inner, [i], p in ItemPrice,
      on: p.item_id == i.id and p.game_mode == ^mode,
      as: :price
    )
    |> where([price: p], not is_nil(p.last_low_price))
    |> order_by([price: p], desc: p.last_low_price, desc: p.item_id)
    |> select([i], i.id)
    |> Repo.all()
  end

  @doc false
  # The whole catalogue, category preloaded, WITHOUT any mode price overlay.
  # Prices are a separate layer precisely so this — the expensive half — is not
  # rebuilt every ten minutes when only prices moved.
  @spec catalog_rows() :: [Item.t()]
  def catalog_rows do
    Item |> preload(:category) |> Repo.all()
  end

  @doc false
  # Every price row for a mode, as the plain map the overlay needs.
  @spec price_rows(any()) :: [map()]
  def price_rows(game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    from(p in ItemPrice,
      where: p.game_mode == ^mode,
      select: %{
        item_id: p.item_id,
        base_price: p.base_price,
        last_low_price: p.last_low_price,
        avg_24h_price: p.avg_24h_price,
        low_24h_price: p.low_24h_price,
        high_24h_price: p.high_24h_price,
        historical_prices: p.historical_prices
      }
    )
    |> Repo.all()
  end

  @doc false
  # The in-memory equivalent of `select_merge_mode_prices/1`, and it must stay
  # that way. A LEFT join with no matching price row yields NULLs for every
  # overlaid column, so a missing price must NULL those fields rather than leave
  # the items table's own values showing — while `base_price` coalesces back to
  # the item's, matching `coalesce(p.base_price, i.base_price)`.
  @spec overlay_price(Item.t(), map() | nil) :: Item.t()
  def overlay_price(item, nil) do
    %{
      item
      | last_low_price: nil,
        avg_24h_price: nil,
        low_24h_price: nil,
        high_24h_price: nil,
        historical_prices: nil
    }
  end

  def overlay_price(item, price) do
    %{
      item
      | base_price: price.base_price || item.base_price,
        last_low_price: price.last_low_price,
        avg_24h_price: price.avg_24h_price,
        low_24h_price: price.low_24h_price,
        high_24h_price: price.high_24h_price,
        historical_prices: price.historical_prices
    }
  end

  @doc false
  # Shared by the dataset's search and by nothing else. Public so the equality
  # tests can assert the tokeniser is the same one the SQL path uses.
  @spec search_tokens(String.t() | nil) :: [String.t()]
  def search_tokens(q), do: normalize_query(q)

  # Every distinct item_id referenced by any (non-blacklisted)
  # objective for `game_mode`, as a `%{uuid: item_id}` union. Shared
  # by the `:quest` scope filter and the per-page category-flag batch
  # (`category_flags_for/2`) so the "Needed for quests" pill and the
  # Quest Items tab always agree on what counts as quest-relevant.
  #
  # Three arms, each casting the extracted text → uuid so the column
  # is type-compatible with `items.id`:
  #
  #   * `payload->'items'`           — turn-in / find / mark targets.
  #   * `payload->'required_key_ids'`— keys the objective needs
  #     brought into raid (just as "needed for a quest" as a turn-in).
  #   * `payload->>'questItem'`      — quest-exclusive items (Golden
  #     Zibbo, Cult medallion, …) referenced via a scalar, not an
  #     array; omitting this arm silently dropped every such item.
  #
  # The `t.name not in @task_name_blacklist` filter mirrors
  # `needed_by_tasks/2` so items referenced *only* by a blacklisted
  # task (Key Partner / Building Foundations / Circulate) don't leak
  # in. Selecting a `%{uuid: ...}` map (rather than a bare column) lets
  # callers wrap this in a subquery and both filter on and re-select
  # `uuid`.
  defp quest_item_union(game_mode) do
    items_subq =
      from(o in Objective,
        join: t in assoc(o, :task),
        select: %{uuid: fragment("(jsonb_array_elements_text(?->'items'))::uuid", o.payload)},
        where:
          fragment("jsonb_typeof(?->'items') = 'array'", o.payload) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode
      )

    keys_subq =
      from(o in Objective,
        join: t in assoc(o, :task),
        select: %{
          uuid: fragment("(jsonb_array_elements_text(?->'required_key_ids'))::uuid", o.payload)
        },
        where:
          fragment("jsonb_typeof(?->'required_key_ids') = 'array'", o.payload) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode
      )

    quest_items_subq =
      from(o in Objective,
        join: t in assoc(o, :task),
        select: %{uuid: fragment("(?->>'questItem')::uuid", o.payload)},
        where:
          fragment("?->>'questItem' IS NOT NULL", o.payload) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode
      )

    items_subq
    |> union_all(^keys_subq)
    |> union_all(^quest_items_subq)
  end

  defp apply_items_sort(query, :name_desc) do
    order_by(query, [i], desc: i.name, asc: i.id)
  end

  # Sort by the item's class (category name). Nil categories sort last under
  # Postgres' default NULLS LAST for ascending; name breaks ties within a class.
  defp apply_items_sort(query, :class_asc) do
    order_by(query, [i, category: c], asc: c.name, asc: i.name, asc: i.id)
  end

  defp apply_items_sort(query, :class_desc) do
    order_by(query, [i, category: c], desc: c.name, asc: i.name, asc: i.id)
  end

  # `:name_asc` (Designation A→Z) is also the natural default, so `:default`
  # and any unknown value fall through here.
  defp apply_items_sort(query, _default) do
    order_by(query, [i], asc: i.name, asc: i.id)
  end

  @doc """
  Item counts per category name across the whole catalog (mode-independent),
  backing the Items-page category filter chips. Every catalog item has a
  category, so the sum matches the total item count.
  """
  def item_counts_by_category do
    Cache.fetch(
      {__MODULE__, :item_counts_by_category},
      ["ItemsSync"],
      &item_counts_by_category_uncached/0
    )
  end

  defp item_counts_by_category_uncached do
    from(i in Item,
      join: c in assoc(i, :category),
      group_by: c.name,
      select: {c.name, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns a map of `category_name => count` of flea-market-eligible
  items (those with a non-nil `last_low_price`), grouped by category
  name. Categories with no flea-eligible items are simply absent.

  Backs the live per-group counts on the Flea Market tab (replacing the
  old hardcoded "X+" labels that drifted from reality).
  """
  def flea_market_counts_by_category(game_mode \\ EftBuddy.GameMode.default()) do
    # Three owners: the category counts come from ItemsSync, but flea
    # eligibility depends on price columns (PricesSync) and on the unlock level
    # (FleaSettingsSync). Any of the three moving makes a cached count untrue, so
    # all three invalidate it.
    Cache.fetch(
      {__MODULE__, :flea_counts_by_category, game_mode},
      ["ItemsSync", "PricesSync", "FleaSettingsSync"],
      fn -> flea_market_counts_by_category_uncached(game_mode) end
    )
  end

  defp flea_market_counts_by_category_uncached(game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    from(i in Item,
      join: c in assoc(i, :category),
      join: p in ItemPrice,
      on: p.item_id == i.id and p.game_mode == ^mode,
      where: not is_nil(p.last_low_price),
      group_by: c.name,
      select: {c.name, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Overlay the active mode's `item_prices` columns onto the selected
  # `%Item{}` struct. Keeping the override on the *struct's own* price
  # fields means every template that reads `item.last_low_price` /
  # `item.base_price` / `item.avg_24h_price` works unchanged in
  # both modes — for PVP these equal the regular mirror; for PVE they're
  # the PVE values. Expects the query to carry a `:price` named binding
  # (inner-joined for the flea listing, left-joined for the full
  # catalog); `base_price` coalesces to the item's own value so catalog
  # rows with no price row (e.g. quest items) keep a base price.
  defp select_merge_mode_prices(query) do
    select_merge(query, [i, price: p], %{
      base_price: coalesce(p.base_price, i.base_price),
      last_low_price: p.last_low_price,
      avg_24h_price: p.avg_24h_price,
      low_24h_price: p.low_24h_price,
      high_24h_price: p.high_24h_price,
      historical_prices: p.historical_prices
    })
  end

  # Left-join the active mode's price row (catalog listings show every
  # item, including ones with no flea price) and overlay it onto the
  # struct. Adds the `:price` binding the price sort and
  # `select_merge_mode_prices/1` rely on.
  defp with_mode_prices(query, game_mode) do
    query
    |> join(:left, [i], p in ItemPrice,
      on: p.item_id == i.id and p.game_mode == ^game_mode,
      as: :price
    )
  end

  @doc """
  Options:
    :limit – page size (default 40)
    :offset – number of rows to skip (default 0)
    :query – free-text search; matches against `name` and `short_name` using AND-of-tokens.
    :category_names  – list of `Category.name` values; when non-empty, only items whose category is in the list are returned.
    :flea_status – `:all` (default), `:buyable`, `:locked`, or `:watchlist`.
                   `:buyable`/`:locked` gate items on whether the operator's
                   `:pmc_level` meets the item's effective flea level —
                   `GREATEST(flea_unlock_level, COALESCE(item.min_level_for_flea,
                   category.min_level_for_flea_market, flea_unlock_level))`.
                   The global flea unlock level is a hard floor, so nothing
                   is buyable below it regardless of the per-item value.
                   `:watchlist` instead ignores the lock state entirely and
                   narrows the listing to the operator's favourited items (see
                   `:favorite_slugs`).
    :pmc_level – operator PMC level, used by `:flea_status` (default 1).
    :favorite_slugs – list of `Item.normalized_name` slugs the operator has
                   added to their watchlist. Only consulted when
                   `:flea_status` is `:watchlist`; an empty list yields no
                   rows. Slugs (not DB ids) are used so a stored watchlist
                   survives a reseed, mirroring how the Tasks page persists
                   completed quests.
  """
  # - Lists items that are listable on the flea market, ordered by their current flea price.
  def list_flea_market_items(opts \\ []) do
    if Dataset.ready?(Keyword.get(opts, :game_mode)) do
      Dataset.list_flea_market_items(opts)
    else
      list_flea_market_items_sql(opts)
    end
  end

  defp list_flea_market_items_sql(opts) do
    limit = Keyword.get(opts, :limit, 40)
    offset = Keyword.get(opts, :offset, 0)
    flea_status = Keyword.get(opts, :flea_status, :all)
    pmc_level = Keyword.get(opts, :pmc_level, 1)
    favorite_slugs = Keyword.get(opts, :favorite_slugs, [])
    floor = flea_unlock_level()

    opts
    |> flea_base_query()
    |> apply_flea_view(flea_status, pmc_level, floor, favorite_slugs)
    |> apply_flea_favorites_first(flea_status, favorite_slugs)
    |> order_by([price: p], desc: p.last_low_price, desc: p.item_id)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:category)
    |> select_merge_mode_prices()
    |> Repo.all()
  end

  # Float watchlisted items to the very top of every NON-watchlist flea
  # listing, so starring an item pushes it to the front of the results
  # (mirroring the Items tab). Added before the price order_by so it wins as
  # the primary sort key, with the price ordering breaking ties within each
  # group. On the watchlist view every row is already a favourite, so ordering
  # is moot; an empty watchlist is a no-op.
  defp apply_flea_favorites_first(query, :watchlist, _slugs), do: query

  defp apply_flea_favorites_first(query, _status, slugs) do
    case Enum.filter(slugs, &(is_binary(&1) and &1 != "")) do
      [] -> query
      cleaned -> order_by(query, [i], desc: fragment("? = ANY(?)", i.normalized_name, ^cleaned))
    end
  end

  @doc """
  Per-status item counts for the Flea Market options bar
  (`%{all: n, buyable: n, locked: n, watchlist: n}`), honoring the current
  search / category context. `:buyable` is everything the operator's
  `:pmc_level` can currently list/trade on the flea; `:locked` is the rest;
  `:watchlist` is how many of the operator's favourited items (see
  `:favorite_slugs`) match the current view. Cheap aggregates over the same
  base query the listing uses, so the badges always match what each tab
  reveals.
  """
  def flea_market_status_counts(opts \\ []) do
    if Dataset.ready?(Keyword.get(opts, :game_mode)) do
      Dataset.flea_market_status_counts(opts)
    else
      flea_market_status_counts_sql(opts)
    end
  end

  defp flea_market_status_counts_sql(opts) do
    pmc_level = Keyword.get(opts, :pmc_level, 1)
    favorite_slugs = Keyword.get(opts, :favorite_slugs, [])
    floor = flea_unlock_level()
    base = flea_base_query(opts)

    total = Repo.aggregate(base, :count, :id)

    buyable =
      base
      |> apply_flea_status(:buyable, pmc_level, floor)
      |> Repo.aggregate(:count, :id)

    watchlist =
      base
      |> apply_favorites(favorite_slugs)
      |> Repo.aggregate(:count, :id)

    %{all: total, buyable: buyable, locked: total - buyable, watchlist: watchlist}
  end

  # Shared base for the flea listing + status counts: every item with a
  # non-nil flea price for the active mode, narrowed by the search query
  # and category filter. Category is left-joined (as `:category`) so the
  # level-based `:flea_status` filter and the category-name filter can
  # both read `min_level_for_flea_market` / `name` off the same binding.
  defp flea_base_query(opts) do
    query = opts |> Keyword.get(:query, "") |> normalize_query()
    category_names = Keyword.get(opts, :category_names, [])
    game_mode = opts |> Keyword.get(:game_mode) |> EftBuddy.GameMode.to_db()

    Item
    |> join(:inner, [i], p in ItemPrice,
      on: p.item_id == i.id and p.game_mode == ^game_mode,
      as: :price
    )
    |> join(:left, [i], c in assoc(i, :category), as: :category)
    |> where([price: p], not is_nil(p.last_low_price))
    |> apply_search(query)
    |> apply_category_names(category_names)
  end

  defp apply_category_names(query, []), do: query
  defp apply_category_names(query, nil), do: query

  defp apply_category_names(query, names) when is_list(names) do
    where(query, [category: c], c.name in ^names)
  end

  # Global PMC level at which the flea market *itself* unlocks. The flea
  # market is inaccessible below this level, full stop — so it acts as a
  # hard FLOOR, not merely a fallback default. The per-item / per-category
  # `minLevelForFlea` from tarkov.dev can only push the requirement
  # *higher* (e.g. the Colt M4A1 is 25); it can never make an item
  # tradeable below the global unlock.
  #
  # This is the crux of the bug this replaced: tarkov.dev reports
  # `minLevelForFlea: 0` for ~1400 tradeable items (mods, low-tier gear,
  # etc.). The old logic `COALESCE(item, category, 15)` used 15 only when
  # the per-item value was NULL, so those `0`-level items resolved to an
  # effective level of 0 and showed as *buyable at level 1* — even though
  # the flea market doesn't open until 15. Flooring with `GREATEST/2`
  # fixes that: `GREATEST(15, 0) = 15`, `GREATEST(15, 25) = 25`.
  #
  # The floor itself is the API's authoritative `fleaMarket.minPlayerLevel`
  # (distinct from per-item `Item.minLevelForFlea`), synced into
  # `game_settings` by `EftBuddy.Items.Sync` and read via
  # `flea_unlock_level/0`. `@default_flea_unlock_level` is the fallback
  # used before the first sync populates it (and matches the live value).
  @default_flea_unlock_level 15
  @flea_unlock_level_key "flea_market_min_player_level"

  @doc """
  The global PMC level at which the flea market unlocks (a hard floor),
  sourced from the API's `fleaMarket.minPlayerLevel` via `game_settings`
  and falling back to #{@default_flea_unlock_level} before the first sync.
  Exposed so the LiveView can phrase the lock copy ("Unlocks at level 15")
  and compute per-card lock state without duplicating the constant.
  """
  def flea_unlock_level do
    # A single-row settings lookup, and the least interesting query in the app —
    # which is exactly why it is worth caching. Every flea listing read, every
    # status-count read and every per-card lock badge calls it, so it is one of
    # the most FREQUENT round trips here despite being one of the cheapest.
    Cache.fetch({__MODULE__, :flea_unlock_level}, ["FleaSettingsSync"], fn ->
      EftBuddy.GameSettings.get_int(@flea_unlock_level_key, @default_flea_unlock_level)
    end)
  end

  @doc false
  # The settings key the flea unlock floor is stored under; the sync
  # writes it, `flea_unlock_level/0` reads it.
  def flea_unlock_level_key, do: @flea_unlock_level_key

  @doc """
  Effective PMC level required to list/trade `item` on the flea market:
  the larger of the global flea unlock `floor` and the item's own
  `min_level_for_flea` (falling back to its category's
  `min_level_for_flea_market`, then the floor). Mirrors the SQL
  `apply_flea_status/4` uses, so the per-card lock badge the LiveView
  renders agrees with the Buyable/Locked tab counts.

  Pass the `floor` explicitly (the LiveView fetches `flea_unlock_level/0`
  once and threads it through its per-card loop); the 1-arity form looks
  it up for one-off callers like the item-detail panel.

  Tolerates an unloaded / missing `:category` association (returns the
  item-or-floor level in that case) so it's safe to call from any
  template that has the item but not necessarily the category preloaded.
  """
  def effective_flea_level(item), do: effective_flea_level(item, flea_unlock_level())

  def effective_flea_level(item, floor) when is_integer(floor) do
    category_level =
      case item do
        %{category: %{min_level_for_flea_market: lvl}} -> lvl
        _ -> nil
      end

    per_item = Map.get(item, :min_level_for_flea)

    max(floor, per_item || category_level || floor)
  end

  @doc """
  Whether `item` is locked on the flea market for an operator at
  `pmc_level` — i.e. their level is below the item's
  `effective_flea_level/2`. Drives the per-card lock badge. Pass `floor`
  (the active `flea_unlock_level/0`) to avoid a per-item settings lookup
  in tight render loops; the 2-arity form looks it up.
  """
  def flea_locked?(item, pmc_level), do: flea_locked?(item, pmc_level, flea_unlock_level())

  def flea_locked?(item, pmc_level, floor) when is_integer(pmc_level) and is_integer(floor) do
    effective_flea_level(item, floor) > pmc_level
  end

  # Dispatch the listing's view filter. `:watchlist` is its own axis —
  # it narrows to the operator's favourited slugs and ignores the
  # buyable/locked lock split entirely — so it's routed here rather than
  # folded into `apply_flea_status/4`. Everything else (`:all`,
  # `:buyable`, `:locked`) defers to the level-based lock filter.
  defp apply_flea_view(query, :watchlist, _pmc_level, _floor, favorite_slugs),
    do: apply_favorites(query, favorite_slugs)

  defp apply_flea_view(query, status, pmc_level, floor, _favorite_slugs),
    do: apply_flea_status(query, status, pmc_level, floor)

  # Narrow a flea query to the operator's watchlist, matched on the
  # stable `normalized_name` slug. An empty/blank list yields no rows
  # (Ecto compiles `IN ()` to a `FALSE` predicate), which is exactly
  # what the empty-watchlist view should show.
  defp apply_favorites(query, slugs) when is_list(slugs) do
    cleaned = Enum.filter(slugs, &(is_binary(&1) and &1 != ""))
    where(query, [i], i.normalized_name in ^cleaned)
  end

  defp apply_favorites(query, _slugs), do: where(query, [i], false)

  # Effective flea-listing level for an item, flooring the per-item /
  # per-category `minLevelForFlea` at the global flea unlock `floor`.
  # `GREATEST(floor, COALESCE(item, category, floor))` keeps the floor
  # authoritative while still honoring the higher per-item restrictions
  # the API sets on premium items.
  defp apply_flea_status(query, :buyable, pmc_level, floor) do
    where(
      query,
      [i, category: c],
      fragment(
        "GREATEST(?, COALESCE(?, ?, ?))",
        ^floor,
        i.min_level_for_flea,
        c.min_level_for_flea_market,
        ^floor
      ) <= ^pmc_level
    )
  end

  defp apply_flea_status(query, :locked, pmc_level, floor) do
    where(
      query,
      [i, category: c],
      fragment(
        "GREATEST(?, COALESCE(?, ?, ?))",
        ^floor,
        i.min_level_for_flea,
        c.min_level_for_flea_market,
        ^floor
      ) > ^pmc_level
    )
  end

  defp apply_flea_status(query, _status, _pmc_level, _floor), do: query

  defp normalize_query(nil), do: ""

  defp normalize_query(q) when is_binary(q) do
    q
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  defp apply_search(query, []), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, tokens) when is_list(tokens) do
    Enum.reduce(tokens, query, fn token, acc ->
      pattern = "%" <> escape_like(token) <> "%"

      where(
        acc,
        [i],
        ilike(i.name, ^pattern) or ilike(i.short_name, ^pattern)
      )
    end)
  end

  # Escape LIKE/ILIKE wildcards so a user typing "%" or "_" matches
  # those characters literally instead of acting as wildcards.
  defp escape_like(token) do
    token
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── Item details (expanded panel) ──────────────────────

  @doc """
  Returns everything the expanded items-page panel needs for a
  single item, in one shape:

      %{
        item: %Item{},
        needed_by_tasks:    [%{task, count, found_in_raid}],
        needed_by_hideout:  [%{station_name, level, quantity}],
        needed_for_crafts:  [%{station_name, station_level, duration, task_unlock, output: %{item, quantity}, required: [%{item, count, quantity, attributes}]}],
        needed_for_barters: [%{trader_name, level, buy_limit, task_unlock, output: %{item, quantity}, required: [%{item, count, quantity, attributes}]}],
        obtained_from_tasks:    [%{task, quantity, phase}],
        obtained_from_barters:  [%{trader_name, level, task_unlock, output_count, output_quantity, required: [%{item, count, quantity, attributes}]}],
        obtained_from_crafts:   [%{station_name, station_level, duration, task_unlock, output_count, output_quantity, required: [%{item, count, quantity, attributes}]}],
        unlocked_from_tasks:    [%{task, trader_name, level, phase}]
      }

  Returns `nil` if the item doesn't exist. Each section is a
  separate query — keeping them small and focused is easier to
  reason about than one giant nested preload, and the round-trip
  cost is negligible (the live latency is dominated by the
  Postgres connection check-out, not by 5 vs 1 statements).
  """
  def get_item_details(item_id, game_mode \\ EftBuddy.GameMode.default())

  def get_item_details(item_id, game_mode) when is_binary(item_id) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    # The item itself is resolved FIRST and separately from the eight relational
    # sections, and the split is the whole reason a ten-minute price tick is
    # affordable here.
    #
    # `:item` is the only part of this payload that depends on prices. Keeping
    # `"PricesSync"` in the relational entry's sources meant every one of these
    # panels was thrown away six times an hour by a feed that changes one of
    # nine keys — so even the lazy cache was rebuilding constantly. Splitting it
    # out makes the relational half live on its owning feeds' schedule, and the
    # price half a memory read.
    #
    # Resolving the item first also stops a nonexistent id minting a cached
    # `nil`: 20,000 random UUIDs used to fill the table.
    case resolve_item(item_id, mode) do
      nil -> nil
      item -> Map.put(relational_details(item.id, mode), :item, item)
    end
  end

  def get_item_details(_, _), do: nil

  # Deliberately WITHOUT "PricesSync" — see `get_item_details/2`.
  @detail_sources ["ItemsSync", "TasksSync", "HideoutSync", "BartersSync", "CraftsSync"]

  @doc false
  # Public so the warm registry and the equality tests can name one list rather
  # than each keeping their own copy. A spec whose sources drift from these is
  # warmed on one schedule and invalidated on another.
  def detail_sources, do: @detail_sources

  @doc false
  def detail_key(item_id, mode), do: {__MODULE__, :item_details_rel, item_id, mode}

  @doc false
  # ONE derivation, shared by the lazy read below, the bulk write in
  # `warm_item_details/1`, and — because the warm registry gives a `:bulk` spec's
  # sentinel `Cache.ttl_for_sources(spec.sources)` and that spec's sources ARE
  # `@detail_sources` — the coverage sentinel too.
  #
  # This replaced a hand-picked 8h, justified as "rebuilt by ItemsSync at six
  # hours, so eight gives headroom". That was true and it was still a trap: it
  # held only because a 6h cadence invalidated the entries and the sentinel
  # together before either could expire, and nothing in the code said so. Move
  # ItemsSync to twelve hours and the entries expire at eight while the sentinel
  # lives to twenty-six — `skip?/1` then refuses to rebuild a set that is already
  # gone, and `coverage/0` reports it `:live`. The inverse is just as bad: a
  # source budget below the entry TTL makes the sentinel expire first, and the
  # five-minute repair tick rebuilds all ~10,898 entries unconditionally because
  # `warm_item_details/1` does not probe.
  #
  # Deriving both ends from the same function makes the two agree by construction
  # instead of by coincidence.
  def detail_ttl_ms, do: Cache.ttl_for_sources(@detail_sources)

  defp relational_details(item_id, mode) do
    Cache.fetch(
      detail_key(item_id, mode),
      @detail_sources,
      fn -> relational_details_uncached(item_id, mode) end,
      # Passed EXPLICITLY here and deliberately omitted at the bulk write. This
      # runs in a web process, which has no `Cache.put_ttl_override/1` set, so
      # leaving it off would fall back to the 20-minute default — the very thing
      # the original constant existed to avoid. The warm path has the override and
      # inherits the same number from it.
      ttl_ms: detail_ttl_ms()
    )
  end

  # Prefers the in-memory price layer, which `PricesSync` already refreshes in
  # one small query, and falls back to SQL exactly like every other dataset
  # read: a miss costs latency, never correctness.
  #
  # `:category` must be loaded either way. The listing query preloads it and the
  # row template reads `row.item.category.name` on every render, so returning a
  # bare `Repo.get/2` result would replace the row's `%Item{}` with one whose
  # `:category` is `%Ecto.Association.NotLoaded{}` and crash the next diff.
  defp resolve_item(item_id, mode) do
    Dataset.item_with_price(item_id, mode) || item_with_mode_price(item_id, mode)
  end

  defp relational_details_uncached(item_id, mode) do
    item_id
    |> then(&[&1])
    |> relational_details_for(mode)
    |> Map.get(item_id, empty_details())
  end

  @doc false
  # Whether the bulk detail build runs. Coerced with `!!` for the same reason
  # `Dataset.enabled?/0` is: `Application.get_env/3`'s default only applies to a
  # MISSING key, so a key explicitly set to nil returns nil, and a nil chained
  # through `and` raises rather than reading as false.
  def details_precompute_enabled?,
    do: !!Application.get_env(:eft_buddy, :item_details_precompute_enabled, false)

  @doc false
  # Precompute every item's relational detail panel for one game mode.
  #
  # 12 queries for the whole catalogue, versus the 11-18 PER ITEM the lazy path
  # costs — because every section query is the same query the lazy path uses,
  # with its subject filter left off.
  #
  # Unlike `ITEM_DATASET`, this flag gates only the BUILDER, never the read
  # path. `get_item_details/2` looks up the same key whichever way the flag is
  # set; with it off the entries simply are not there and every read is lazy. So
  # turning this off can change latency and can never change an answer, which is
  # why it needs far less ceremony than the dataset layer — that one gates a
  # read path which reimplements query semantics.
  def warm_item_details(game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    if details_precompute_enabled?() do
      # Seeded with EVERY item id, not just the ones the section queries
      # returned. `relational_details_for/2` keys its result on ids that appear
      # in at least one section, and on the real catalogue that is only about a
      # third of it — the rest are loot, mods and ammo with no task, hideout,
      # barter or craft involvement at all. Without this they get no entry and
      # stay fully lazy, which measured as 1,772 of 5,449 items precomputed and
      # the other 3,677 exactly as slow as before.
      #
      # An empty panel is a real answer and costs eight empty lists to store.
      # One extra query buys the other two thirds of the catalogue.
      all_ids = Repo.all(from(i in Item, select: i.id))
      built = relational_details_for(:all, mode)

      all_ids
      |> Map.new(fn id -> {id, Map.get(built, id, empty_details())} end)
      |> Enum.chunk_every(Cache.warm_chunk_size())
      |> Enum.reduce_while({0, [], Cache.memory_bytes()}, fn chunk, {n, written, start_bytes} ->
        keys = Enum.map(chunk, fn {id, _} -> detail_key(id, mode) end)

        # No `ttl_ms:` on purpose. This runs inside a warm task, which has already
        # set `Cache.put_ttl_override/1` to `Cache.ttl_for_sources(spec.sources)` —
        # the same value the coverage sentinel will be written with moments later.
        # Inheriting it is what makes the set and its sentinel expire together by
        # construction; passing a constant here is what let them drift apart.
        Cache.put_many(
          Enum.map(chunk, fn {id, details} -> {detail_key(id, mode), details} end),
          @detail_sources
        )

        written = keys ++ written
        grown = Cache.memory_bytes() - start_bytes

        if grown > details_max_bytes() do
          # Unwind. A half-written set left in the table is memory spent on
          # entries the build has just decided it should not have spent — and
          # every reader falls back to the lazy path for a missing key, so
          # dropping them costs latency and nothing else.
          #
          # The `{:skip, _}` this returns is what withholds the coverage sentinel.
          # It used to return `{:ok, 0}`, and `Cache.Warmer.record_outcome/4`
          # stamps a sentinel for ANY `{:ok, _}` — so the unwind marked the set
          # warm over entries it had just deleted, `skip?/1` suppressed every
          # repair tick until that sentinel expired, and `coverage/0` reported the
          # spec `:live` with nothing behind it. The comment here claimed the
          # opposite for as long as the bug existed.
          Cache.drop(written)

          Logger.error("""
          [Items] item detail precompute for #{mode} exceeded its memory budget \
          (#{div(grown, 1_048_576)}MB > #{div(details_max_bytes(), 1_048_576)}MB) \
          after #{n + length(chunk)} panels. Dropped what it wrote; panels stay \
          lazy. Raise :item_details_max_bytes (env ITEM_DETAILS_MAX_MB) if the \
          box genuinely has the headroom, or leave ITEM_DETAILS off.\
          """)

          :telemetry.execute(
            [:eft_buddy, :items, :details_build],
            %{bytes: grown, entries: 0},
            %{mode: mode, outcome: :over_budget}
          )

          {:halt, {:error, :over_budget}}
        else
          Process.sleep(Cache.warm_chunk_pause_ms())
          {:cont, {n + length(chunk), written, start_bytes}}
        end
      end)
      |> case do
        {:error, :over_budget} ->
          {:skip, :over_budget}

        {n, _written, start_bytes} ->
          :telemetry.execute(
            [:eft_buddy, :items, :details_build],
            %{bytes: Cache.memory_bytes() - start_bytes, entries: n},
            %{mode: mode, outcome: :ok}
          )

          {:ok, n}
      end
    else
      {:ok, 0}
    end
  end

  # Ceiling on how much this build may add to the cache table.
  #
  # Bounds the PERSISTENT cost only. The transient peak is larger and not
  # covered: `relational_details_for(:all, …)` materialises every section for
  # the whole catalogue before the first entry is written, so the build's own
  # high-water mark is reached before this check ever runs. Bounding that too
  # would mean streaming the build per chunk of items, which costs a query set
  # per chunk instead of twelve in total.
  defp details_max_bytes do
    Application.get_env(:eft_buddy, :item_details_max_bytes, 250 * 1_048_576)
  end

  # ── The subject switch ─────────────────────────────────
  #
  # Every section query below is written ONCE and parameterised by its subject:
  # `[item_id]` for one panel, `:all` for the bulk build. Writing the nine
  # sections twice — a per-item version and a whole-catalogue version — would
  # be nine chances for the two to drift, and the failure mode is a panel that
  # renders perfectly while being wrong. `EftBuddy.Items.Dataset` avoided the
  # same trap by calling the very `apply_scope/3` the SQL path uses; this is
  # that lesson applied literally.
  #
  # Each section's pivot table carries `as: :subject`, so one clause covers all
  # of them.

  defp for_subject(query, :all), do: query

  defp for_subject(query, ids) when is_list(ids),
    do: where(query, [subject: s], s.item_id in ^ids)

  # Rows come back carrying their subject's id; this strips it and buckets them.
  # `Enum.group_by/3` preserves order of appearance within each key, so slicing
  # a globally-ordered result per item reproduces exactly what a per-item
  # `ORDER BY` would have returned — provided the sort key is total and does not
  # involve the subject, which is why the tiebreakers below were added.
  defp group_by_subject(rows),
    do: Enum.group_by(rows, & &1.item_id, &Map.delete(&1, :item_id))

  defp at(grouped, item_id), do: Map.get(grouped, item_id, [])

  # Every key present and empty, not absent. An item with no relations at all is
  # the likeliest thing to get wrong here, and a missing key crashes the
  # template rather than rendering an empty section.
  defp empty_details do
    %{
      needed_by_tasks: [],
      needed_by_hideout: [],
      needed_for_crafts: [],
      needed_for_barters: [],
      obtained_from_tasks: [],
      obtained_from_barters: [],
      obtained_from_crafts: [],
      unlocked_from_tasks: []
    }
  end

  # Build the eight relational sections for `subject` (`:all` or a list of ids)
  # in one pass, returning `%{item_id => details_map}`.
  #
  # 12 queries per mode, whether that covers one item or five thousand.
  defp relational_details_for(subject, mode) do
    needed_by_tasks = needed_by_tasks_rows(subject, mode)
    needed_by_hideout = needed_by_hideout_rows(subject)
    needed_for_crafts = needed_for_crafts_rows(subject)
    needed_for_barters = needed_for_barters_rows(subject, mode)
    obtained_from_tasks = obtained_from_tasks_rows(subject, mode)
    obtained_from_barters = obtained_from_barters_rows(subject, mode)
    obtained_from_crafts = obtained_from_crafts_rows(subject)
    unlocked_from_tasks = unlocked_from_tasks_rows(subject, mode)

    [
      needed_by_tasks,
      needed_by_hideout,
      needed_for_crafts,
      needed_for_barters,
      obtained_from_tasks,
      obtained_from_barters,
      obtained_from_crafts,
      unlocked_from_tasks
    ]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Map.new(fn id ->
      {id,
       %{
         needed_by_tasks: at(needed_by_tasks, id),
         needed_by_hideout: at(needed_by_hideout, id),
         needed_for_crafts: at(needed_for_crafts, id),
         needed_for_barters: at(needed_for_barters, id),
         obtained_from_tasks: at(obtained_from_tasks, id),
         obtained_from_barters: at(obtained_from_barters, id),
         obtained_from_crafts: at(obtained_from_crafts, id),
         unlocked_from_tasks: at(unlocked_from_tasks, id)
       }}
    end)
  end

  # Fetch one item with the active mode's prices overlaid onto its
  # struct fields (same overlay the listing queries use), plus the
  # :category preload the row template needs.
  defp item_with_mode_price(item_id, mode) do
    Item
    |> where([i], i.id == ^item_id)
    |> with_mode_prices(mode)
    |> preload(:category)
    |> select_merge_mode_prices()
    |> Repo.one()
  end

  # Task objectives that include this item — either as a target
  # (the player has to find / hand in / mark / build it) or as a
  # required key to complete the objective (the player has to
  # bring it into raid to open a door, etc).
  #
  # We run two queries and merge:
  #
  #   1. *Item* references via `payload->'items'`. Some quests
  #      split a single demand across multiple objective rows for
  #      the same item — we collapse on `(task_id, foundInRaid)`
  #      and take `MAX(count)` to dedupe without inflating the
  #      requirement (see commit history for the rationale).
  #
  #   2. *Key* references via `payload->'required_key_ids'`. Keys
  #      have no count / FiR semantics — the player just needs to
  #      have the key in their stash to enter raid with it. We
  #      surface them as a third sentence variant (`kind: :key`).
  #
  # Sentence selection rule: if this item is referenced as a key
  # by *any* quest in the database, we treat it as fundamentally
  # a key item and rewrite every quest reference (including ones
  # that came in via `payload.items`) to the `:key` sentence
  # variant. This matches the user's mental model — "if it's a
  # key, the line should always read 'This is needed for the
  # quest …'" — without us having to maintain a hand-curated
  # list of key categories or guess from item names. Quests
  # that reference the key only via `payload.items` are still
  # surfaced (we don't drop them), they just get the key sentence
  # instead of a numeric "needs to be obtained" one.
  defp needed_by_tasks_rows(subject, game_mode) do
    key_ids = key_item_ids(game_mode)

    item_rows =
      subject
      |> objective_array_rows(game_mode, "items")
      |> Enum.map(fn row ->
        # When the item is a key, rewrite the kind so the template renders the
        # key sentence. The count / found_in_raid fields are still in the map
        # but the `:key` clause of `quest_needed_sentence/1` ignores them.
        if MapSet.member?(key_ids, row.item_id), do: %{row | kind: :key}, else: row
      end)

    key_rows =
      subject
      |> objective_array_rows(game_mode, "required_key_ids")
      |> Enum.map(&%{&1 | kind: :key, count: 1, found_in_raid: false})
      |> Enum.uniq_by(&{&1.item_id, &1.task_id})

    # Quest-exclusive items (Golden Zibbo lighter, Cult medallion,
    # …) are referenced by their objective via the scalar
    # `payload->>'questItem'` key, NOT the `payload->'items'`
    # array — so without this arm a quest item's panel would show
    # an empty "Needed by quests" section even though it exists
    # purely to be collected for one quest. We resolve the same
    # way the API does (a single local UUID string) and surface it
    # with the numeric "needs to be obtained" sentence, identical
    # to a regular find/handover item. As with `item_rows`, if the
    # item is *also* used as a key anywhere we rewrite the kind so
    # the key sentence wins (a quest-item-that-is-also-a-key is
    # vanishingly rare, but keeping the rule uniform avoids
    # surprising phrasing drift).
    quest_item_rows =
      from(o in Objective,
        as: :subject,
        join: t in assoc(o, :task),
        where:
          not is_nil(fragment("?->>'questItem'", o.payload)) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        group_by: [fragment("?->>'questItem'", o.payload), t.id, t.name],
        order_by: [asc: t.name, asc: t.id],
        select: %{
          item_id: fragment("?->>'questItem'", o.payload),
          kind: :item,
          task_id: t.id,
          task_name: t.name,
          count: type(max(fragment("COALESCE((?->>'count')::int, 1)", o.payload)), :integer),
          found_in_raid: false
        }
      )
      |> quest_item_subject(subject)
      |> Repo.all()
      |> Enum.map(fn row ->
        if MapSet.member?(key_ids, row.item_id), do: %{row | kind: :key}, else: row
      end)

    # Everything above is now grouped per SUBJECT before the dedupe rules run,
    # because those rules are per-item: "prefer the item row over the key row
    # FOR THIS ITEM". Applying them across the whole catalogue at once would
    # let one item's task suppress another's.
    by_item = group_by_subject(item_rows)
    quest_by_item = group_by_subject(quest_item_rows)
    keys_by_item = group_by_subject(key_rows)

    [by_item, quest_by_item, keys_by_item]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Map.new(fn id ->
      {id, merge_task_rows(at(by_item, id), at(quest_by_item, id), at(keys_by_item, id))}
    end)
  end

  # Prefer `:item` rows when a task appears in more than one set — the item
  # demand is the "real" requirement, the key is incidental. The
  # `payload.items` and `payload.questItem` rows are the "item side" (deduping
  # the latter against the former), then any key row for a task already covered
  # by the item side is dropped. When the item is also a key the item-side rows
  # were already rewritten to `:key`, so this still does the right thing — it
  # just deduplicates by task_id.
  defp merge_task_rows(item_rows, quest_item_rows, key_rows) do
    item_task_ids = MapSet.new(item_rows, & &1.task_id)

    deduped_quest_items =
      Enum.reject(quest_item_rows, &MapSet.member?(item_task_ids, &1.task_id))

    item_side_task_ids =
      MapSet.union(item_task_ids, MapSet.new(deduped_quest_items, & &1.task_id))

    deduped_keys = Enum.reject(key_rows, &MapSet.member?(item_side_task_ids, &1.task_id))

    # Sorted in ELIXIR, not by an `ORDER BY`, and that is deliberate: this is
    # byte order, whereas Postgres would apply its collation. Supabase's
    # collation ignores leading punctuation, so moving this into SQL would
    # silently reorder every quest list in production while looking correct
    # locally — the same trap `EftBuddy.Items.Dataset` documents.
    #
    # `Enum.sort_by/2` is stable, so the concatenation order below decides
    # name-ties. The queries feeding it are now totally ordered, which is what
    # makes that reproducible between the per-item and whole-catalogue paths.
    (item_rows ++ deduped_quest_items ++ deduped_keys)
    |> Enum.sort_by(& &1.task_name)
  end

  # Objective rows whose `payload->'<field>'` ARRAY contains an item, inverted:
  # one row per (item, task) rather than a containment test per item.
  #
  # The set-returning function sits in a subquery's SELECT, never in a LATERAL
  # join. Postgres evaluates a SRF in the select list AFTER the WHERE clause, so
  # the `jsonb_typeof(...) = 'array'` guard genuinely protects it; in a LATERAL
  # it is evaluated in the FROM clause, before the filter, and raises "cannot
  # extract elements from an object" on the first non-array payload. That
  # failure would pass every test whose fixtures happen to be well-formed.
  # `quest_item_union/1` above already does it this way.
  #
  # The extracted id is compared as TEXT, never cast to `::uuid`. Ecto's
  # `:binary_id` loads as the canonical lowercase 36-char string and `@>` on a
  # jsonb text array is exact string equality, so text is byte-equivalent to the
  # containment test it replaces — while `::uuid` would be more permissive
  # (normalising case and brace forms) and would RAISE on a malformed string
  # instead of quietly not matching.
  defp objective_array_rows(subject, game_mode, field) do
    inner =
      from(o in Objective,
        join: t in assoc(o, :task),
        where:
          fragment("jsonb_typeof(?->?) = 'array'", o.payload, ^field) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        select: %{
          task_id: t.id,
          task_name: t.name,
          item_id: fragment("jsonb_array_elements_text(?->?)", o.payload, ^field),
          fir: fragment("COALESCE((?->>'foundInRaid')::bool, false)", o.payload),
          cnt: fragment("COALESCE((?->>'count')::int, 1)", o.payload)
        }
      )

    from(x in subquery(inner),
      as: :subject,
      group_by: [x.item_id, x.task_id, x.task_name, x.fir],
      # `MAX(count)` per (item, task, fir) is unchanged in meaning from the
      # per-item version, whose WHERE had already pinned the item. A duplicate
      # id inside one objective's array expands to two rows in the same group,
      # so MAX over the same scalar does not inflate it.
      order_by: [asc: x.task_name, asc: x.task_id, asc: x.fir],
      select: %{
        item_id: x.item_id,
        kind: :item,
        task_id: x.task_id,
        task_name: x.task_name,
        count: type(max(x.cnt), :integer),
        found_in_raid: x.fir
      }
    )
    |> for_subject(subject)
    |> Repo.all()
  end

  # Every item referenced as a required key by ANY non-blacklisted quest.
  #
  # One query for the whole catalogue, replacing a per-item `EXISTS` that ran
  # 5,449 times per mode. The rule it encodes is unchanged: if an item is used
  # as a key anywhere, every reference to it reads as a key.
  defp key_item_ids(game_mode) do
    inner =
      from(o in Objective,
        join: t in assoc(o, :task),
        where:
          fragment("jsonb_typeof(?->'required_key_ids') = 'array'", o.payload) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        select: %{
          item_id: fragment("jsonb_array_elements_text(?->'required_key_ids')", o.payload)
        }
      )

    from(x in subquery(inner), distinct: true, select: x.item_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # `questItem` is a SCALAR, so there is no array to expand and the grouped
  # id is already the subject — but it is text, and `for_subject/2` compares
  # against a `:binary_id` column elsewhere, so it needs its own clause.
  defp quest_item_subject(query, :all), do: query

  defp quest_item_subject(query, ids) when is_list(ids) do
    strings = Enum.map(ids, &uuid_to_string/1)

    where(query, [o], fragment("?->>'questItem'", o.payload) in ^strings)
  end

  defp needed_by_hideout_rows(subject) do
    from(r in HideoutItemRequirement,
      as: :subject,
      join: l in assoc(r, :level),
      join: s in assoc(l, :station),
      select: %{
        item_id: r.item_id,
        station_name: s.name,
        station_slug: s.normalized_name,
        level: l.level,
        quantity: r.quantity
      },
      # `asc: r.id` makes the order TOTAL. Without it two requirements on the
      # same station and level tie, and a globally-ordered query can break that
      # tie differently from a per-item one — so the same panel would render in
      # a different order depending on how it was built. Insertion order matches
      # the API's declaration order.
      order_by: [asc: s.name, asc: l.level, asc: r.id]
    )
    |> for_subject(subject)
    |> Repo.all()
    |> group_by_subject()
  end

  # Tasks that grant this item as a reward, with the phase
  # (start = on-accept, finish = on-turn-in) so the UI can label.
  defp obtained_from_tasks_rows(subject, game_mode) do
    from(r in ItemReward,
      as: :subject,
      join: t in assoc(r, :task),
      where: t.game_mode == ^game_mode,
      select: %{
        item_id: r.item_id,
        task_id: t.id,
        task_name: t.name,
        quantity: r.quantity,
        phase: r.reward_phase
      },
      order_by: [asc: t.name, asc: t.id, asc: r.id]
    )
    |> for_subject(subject)
    |> Repo.all()
    |> group_by_subject()
  end

  # Tasks that unlock this item as a *trader offer* — i.e. after
  # completing the task, the trader starts selling this item at a
  # given loyalty level. This is the `offerUnlock` reward in the
  # API (distinct from `item_rewards`, which hand the item over
  # directly). Surfaced so the per-item panel can tell the player
  # "you can buy this from Prapor LL2 once you finish <quest>",
  # which is often the cheapest/only route to an otherwise
  # locked item. Ordered by trader then loyalty level for a
  # stable, scannable list.
  defp unlocked_from_tasks_rows(subject, game_mode) do
    from(ou in OfferUnlock,
      as: :subject,
      join: t in assoc(ou, :task),
      join: tr in assoc(ou, :trader),
      where: t.game_mode == ^game_mode,
      select: %{
        item_id: ou.item_id,
        task_id: t.id,
        task_name: t.name,
        trader_name: tr.name,
        trader_slug: tr.normalized_name,
        level: ou.level,
        phase: ou.reward_phase
      },
      order_by: [asc: tr.name, asc: ou.level, asc: ou.id]
    )
    |> for_subject(subject)
    |> Repo.all()
    |> group_by_subject()
  end

  # Barters whose `rewardItems` contains this item. We pull the full
  # required-items list per barter so the UI can render the cost
  # column without a follow-up query.
  defp obtained_from_barters_rows(subject, game_mode) do
    barters =
      from(rw in BarterRewardItem,
        as: :subject,
        join: b in assoc(rw, :barter),
        join: tr in assoc(b, :trader),
        left_join: tu in assoc(b, :task_unlock),
        # Trader the *unlock task* belongs to. Almost always the
        # same as `tr` (the barter's trader), but we pull it
        # separately so the "After completing X task Y" line is
        # accurate even on the rare cross-trader unlock.
        left_join: tut in assoc(tu, :trader),
        where: b.game_mode == ^game_mode,
        order_by: [asc: tr.name, asc: b.level, asc: rw.id],
        select: %{
          item_id: rw.item_id,
          barter_id: b.id,
          trader_name: tr.name,
          trader_slug: tr.normalized_name,
          level: b.level,
          buy_limit: b.buy_limit,
          task_unlock_id: tu.id,
          task_unlock_name: tu.name,
          task_unlock_trader_name: tut.name,
          output_count: rw.count,
          output_quantity: rw.quantity
        }
      )
      |> for_subject(subject)
      |> Repo.all()

    required = barter_required_items(barters)

    barters
    |> Enum.map(fn b -> Map.put(b, :required, Map.get(required, b.barter_id, [])) end)
    |> group_by_subject()
  end

  # ── Recipe children ────────────────────────────────────
  #
  # The ingredient and output lists for a set of barters or crafts. Shared
  # between the "obtained from" and "needed for" directions, which each used to
  # build their own copy of the identical query.
  #
  # Filtering on the parent ids we already found keeps ONE query shape for both
  # the single-panel and whole-catalogue cases, which is the point: the empty
  # list is the only special case, and it exists because `IN ()` is not valid
  # SQL rather than for any semantic reason.

  defp barter_required_items([]), do: %{}

  defp barter_required_items(barters) do
    from(rq in BarterRequiredItem,
      join: i in assoc(rq, :item),
      where: rq.barter_id in ^parent_ids(barters, :barter_id),
      # This query had NO `order_by` at all, so the ingredient tiles rendered in
      # whatever order Postgres happened to return — stable enough per item,
      # but not something a query over every barter would reproduce. `asc: rq.id`
      # makes it defined; the ids are insertion-ordered by the syncer, so this
      # is the API's own declaration order.
      order_by: [asc: rq.id],
      select: %{
        barter_id: rq.barter_id,
        item: i,
        count: rq.count,
        quantity: rq.quantity,
        attributes: rq.attributes
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.barter_id, &Map.delete(&1, :barter_id))
  end

  defp barter_outputs([]), do: %{}

  defp barter_outputs(barters) do
    from(rw in BarterRewardItem,
      join: i in assoc(rw, :item),
      where: rw.barter_id in ^parent_ids(barters, :barter_id),
      order_by: [asc: rw.id],
      select: %{barter_id: rw.barter_id, item: i, quantity: rw.quantity}
    )
    |> Repo.all()
    # First-write-wins because the query is ordered ASC — the primary output.
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, row.barter_id, Map.delete(row, :barter_id))
    end)
  end

  defp craft_required_items([]), do: %{}

  defp craft_required_items(crafts) do
    from(rq in CraftRequiredItem,
      join: i in assoc(rq, :item),
      where: rq.craft_id in ^parent_ids(crafts, :craft_id),
      order_by: [asc: rq.id],
      select: %{
        craft_id: rq.craft_id,
        item: i,
        count: rq.count,
        quantity: rq.quantity,
        attributes: rq.attributes
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.craft_id, &Map.delete(&1, :craft_id))
  end

  defp craft_outputs([]), do: %{}

  defp craft_outputs(crafts) do
    from(rw in CraftRewardItem,
      join: i in assoc(rw, :item),
      where: rw.craft_id in ^parent_ids(crafts, :craft_id),
      order_by: [asc: rw.id],
      select: %{craft_id: rw.craft_id, item: i, quantity: rw.quantity}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, row.craft_id, Map.delete(row, :craft_id))
    end)
  end

  # Deduped: the whole-catalogue query returns one row per (parent, subject),
  # so a barter rewarding two items appears twice and would otherwise be named
  # twice in the `IN` list.
  defp parent_ids(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq()

  # Same shape as `obtained_from_barters/1` but joining through
  # crafts → station_level → station so the UI can show
  # "Workbench level 2 (45m)".
  defp obtained_from_crafts_rows(subject) do
    crafts =
      from(rw in CraftRewardItem,
        as: :subject,
        join: c in assoc(rw, :craft),
        join: l in assoc(c, :station_level),
        join: s in assoc(l, :station),
        left_join: tu in assoc(c, :task_unlock),
        # Trader who gives the unlock task. Crafts can be gated
        # by any trader's task (Mechanic ammunition crafts etc.),
        # so we surface this so the UI can phrase it as
        # "After completing <trader> task <task>".
        left_join: tut in assoc(tu, :trader),
        order_by: [asc: s.name, asc: l.level, asc: rw.id],
        select: %{
          item_id: rw.item_id,
          craft_id: c.id,
          station_name: s.name,
          station_slug: s.normalized_name,
          station_level: l.level,
          duration: c.duration,
          task_unlock_id: tu.id,
          task_unlock_name: tu.name,
          task_unlock_trader_name: tut.name,
          output_count: rw.count,
          output_quantity: rw.quantity
        }
      )
      |> for_subject(subject)
      |> Repo.all()

    required = craft_required_items(crafts)

    crafts
    |> Enum.map(fn c -> Map.put(c, :required, Map.get(required, c.craft_id, [])) end)
    |> group_by_subject()
  end

  # Crafts that *consume* this item as an input. Mirror of
  # `obtained_from_crafts/1` — same shape (station / duration /
  # task gate), same recipe-row layout in the UI — but the join
  # starts at `CraftRequiredItem` filtered by `item_id`, so we
  # find every craft whose ingredient list includes this item.
  #
  # We pull two extra things per craft compared to the obtained
  # variant:
  #
  #   * the full `required_items` list, so the UI can render
  #     every input tile and highlight the *current* item among
  #     them (mirroring how the obtained variant highlights the
  #     output tile).
  #   * the craft's reward (`output`) — a single item with its
  #     quantity — so the recipe row can show the same
  #     "inputs → output" arrow shape as the obtained section,
  #     keeping the panel visually consistent.
  #
  # Crafts can have multiple reward items, but in the live data
  # this is rare and almost always represents a primary output
  # plus by-products. We surface only the primary (first) reward
  # here so the row stays a single line; if we ever need to
  # expose by-products this is the place to extend.
  defp needed_for_crafts_rows(subject) do
    crafts =
      from(rq in CraftRequiredItem,
        as: :subject,
        join: c in assoc(rq, :craft),
        join: l in assoc(c, :station_level),
        join: s in assoc(l, :station),
        left_join: tu in assoc(c, :task_unlock),
        # Same trader-of-the-unlock-task pull as `obtained_from_crafts_rows/1`
        # so the "After completing <trader> task <task>" copy renders
        # identically in both directions.
        left_join: tut in assoc(tu, :trader),
        order_by: [asc: s.name, asc: l.level, asc: rq.id],
        select: %{
          item_id: rq.item_id,
          craft_id: c.id,
          station_name: s.name,
          station_slug: s.normalized_name,
          station_level: l.level,
          duration: c.duration,
          task_unlock_id: tu.id,
          task_unlock_name: tu.name,
          task_unlock_trader_name: tut.name
        }
      )
      |> for_subject(subject)
      |> Repo.all()

    # The SAME two child maps `obtained_from_crafts_rows/1` builds. Each
    # direction used to compute its own copy of an identical query.
    required = craft_required_items(crafts)
    output = craft_outputs(crafts)

    crafts
    |> Enum.map(fn c ->
      c
      |> Map.put(:required, Map.get(required, c.craft_id, []))
      |> Map.put(:output, Map.get(output, c.craft_id))
    end)
    |> group_by_subject()
  end

  # Barters whose `requiredItems` contains this item — i.e. the
  # ways the user can SPEND this item at a trader. Mirror image
  # of `obtained_from_barters/1`: same parent + child shape, but
  # we pivot the outer query on `BarterRequiredItem` instead of
  # `BarterRewardItem`.
  #
  # Returns each barter with:
  #
  #   * the full required-items list (`:required`) so the recipe
  #     row can render every input tile and highlight the *current*
  #     item among them, mirroring how `needed_for_crafts/1`
  #     highlights its input.
  #   * the barter's primary reward (`:output`) so the row reads
  #     "<inputs> → <output>" identically to the crafts side.
  #
  # Like crafts, barters can technically have multiple rewards.
  # In the live data this is rare; we surface only the first one
  # (id-ordered for stability) to keep the row a single line.
  # If a multi-reward barter ever needs full enumeration, this
  # is the place to extend.
  defp needed_for_barters_rows(subject, game_mode) do
    barters =
      from(rq in BarterRequiredItem,
        as: :subject,
        join: b in assoc(rq, :barter),
        join: tr in assoc(b, :trader),
        left_join: tu in assoc(b, :task_unlock),
        # Trader the *unlock task* belongs to. Same pattern as
        # `obtained_from_barters_rows/2` — usually equal to the barter's
        # trader, but pulled separately for accuracy on cross-trader
        # unlocks.
        left_join: tut in assoc(tu, :trader),
        where: b.game_mode == ^game_mode,
        order_by: [asc: tr.name, asc: b.level, asc: rq.id],
        select: %{
          item_id: rq.item_id,
          barter_id: b.id,
          trader_name: tr.name,
          trader_slug: tr.normalized_name,
          level: b.level,
          buy_limit: b.buy_limit,
          task_unlock_id: tu.id,
          task_unlock_name: tu.name,
          task_unlock_trader_name: tut.name
        }
      )
      |> for_subject(subject)
      |> Repo.all()

    required = barter_required_items(barters)
    output = barter_outputs(barters)

    barters
    |> Enum.map(fn b ->
      b
      |> Map.put(:required, Map.get(required, b.barter_id, []))
      |> Map.put(:output, Map.get(output, b.barter_id))
    end)
    |> group_by_subject()
  end

  # Normalize an item id to its canonical string UUID. Accepts an
  # already-stringified UUID (36 chars = 288 bits) as-is, or casts a
  # raw 16-byte binary via Ecto.UUID. Used to build the `::text`
  # params for the JSONB containment checks in the queries above.
  defp uuid_to_string(<<_::288>> = uuid_str), do: uuid_str

  defp uuid_to_string(<<_::128>> = uuid_bin) do
    case Ecto.UUID.cast(uuid_bin) do
      {:ok, str} -> str
      :error -> raise ArgumentError, "invalid UUID"
    end
  end
end
