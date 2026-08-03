defmodule EftBuddy.Items do
  @moduledoc """
  The Items context. Manages items, categories, vendors, and their relationships.
  """

  import Ecto.Query

  alias EftBuddy.Hideout.ItemRequirement, as: HideoutItemRequirement
  # Only the *RequiredItem / *RewardItem schemas are referenced by
  # name here — the bare `Craft` / `Barter` modules are reached via
  # `assoc(rw, :barter)` / `assoc(rw, :craft)` joins, which don't
  # need an explicit alias.
  alias EftBuddy.Items.{BarterRequiredItem, BarterRewardItem}
  alias EftBuddy.Items.{CraftRequiredItem, CraftRewardItem}
  alias EftBuddy.Items.{Item, ItemPrice}
  alias EftBuddy.Cache
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
    # Keyed by item id, so the key space is the catalogue (5,198) rather than
    # unbounded — but it is still far larger than the whole-list entries, which
    # is why `EftBuddy.Cache` now carries an entry ceiling and an expiry sweep.
    #
    # Everything this returns is sync-written: the item and its prices, the
    # tasks that need it, the hideout levels that consume it, and its barters
    # and crafts. Five owners, because the panel is a join across five feeds and
    # a stale line in any of them is a wrong answer on the page.
    Cache.fetch(
      {__MODULE__, :item_details, item_id, EftBuddy.GameMode.to_db(game_mode)},
      ["ItemsSync", "PricesSync", "TasksSync", "HideoutSync", "BartersSync", "CraftsSync"],
      fn -> get_item_details_uncached(item_id, game_mode) end
    )
  end

  def get_item_details(_, _), do: nil

  defp get_item_details_uncached(item_id, game_mode) do
    mode = EftBuddy.GameMode.to_db(game_mode)

    # Preload :category here because the LiveView's row template
    # reads `row.item.category.name` on every render. The listing
    # query (`list_all_items/1`) preloads it; if we returned a bare
    # Repo.get/2 result, expanding a row would replace the original
    # %Item{} with one whose `:category` is `%Ecto.Association.NotLoaded{}`,
    # crashing the next diff cycle. We also overlay the active mode's
    # prices so the expanded panel matches the row.
    case item_with_mode_price(item_id, mode) do
      nil ->
        nil

      item ->
        %{
          item: item,
          needed_by_tasks: needed_by_tasks(item.id, mode),
          needed_by_hideout: needed_by_hideout(item.id),
          needed_for_crafts: needed_for_crafts(item.id),
          needed_for_barters: needed_for_barters(item.id, mode),
          obtained_from_tasks: obtained_from_tasks(item.id, mode),
          obtained_from_barters: obtained_from_barters(item.id, mode),
          obtained_from_crafts: obtained_from_crafts(item.id),
          unlocked_from_tasks: unlocked_from_tasks(item.id, mode)
        }
    end
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
  defp needed_by_tasks(item_id, game_mode) do
    item_id_str = uuid_to_string(item_id)
    item_is_key? = item_used_as_key?(item_id_str, game_mode)

    item_rows =
      from(o in Objective,
        join: t in assoc(o, :task),
        where:
          fragment(
            "jsonb_typeof(?->'items') = 'array' AND ? @> jsonb_build_array(?::text)",
            o.payload,
            o.payload["items"],
            ^item_id_str
          ) and t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        group_by: [
          t.id,
          t.name,
          fragment("COALESCE((?->>'foundInRaid')::bool, false)", o.payload)
        ],
        select: %{
          kind: :item,
          task_id: t.id,
          task_name: t.name,
          count: type(max(fragment("COALESCE((?->>'count')::int, 1)", o.payload)), :integer),
          found_in_raid: fragment("COALESCE((?->>'foundInRaid')::bool, false)", o.payload)
        }
      )
      |> Repo.all()
      # When the item is a key, rewrite the kind so the template
      # renders the key sentence. The count / found_in_raid fields
      # are still in the map but the `:key` clause of
      # `quest_needed_sentence/1` ignores them.
      |> Enum.map(fn row ->
        if item_is_key?, do: %{row | kind: :key}, else: row
      end)

    key_rows =
      from(o in Objective,
        join: t in assoc(o, :task),
        where:
          fragment(
            "jsonb_typeof(?->'required_key_ids') = 'array' AND ? @> jsonb_build_array(?::text)",
            o.payload,
            o.payload["required_key_ids"],
            ^item_id_str
          ) and t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        distinct: true,
        select: %{
          kind: :key,
          task_id: t.id,
          task_name: t.name,
          count: 1,
          found_in_raid: false
        }
      )
      |> Repo.all()

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
        join: t in assoc(o, :task),
        where:
          fragment("?->>'questItem' = ?", o.payload, ^item_id_str) and
            t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
        group_by: [t.id, t.name],
        select: %{
          kind: :item,
          task_id: t.id,
          task_name: t.name,
          count: type(max(fragment("COALESCE((?->>'count')::int, 1)", o.payload)), :integer),
          found_in_raid: false
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        if item_is_key?, do: %{row | kind: :key}, else: row
      end)

    # Prefer `:item` rows when a task appears in more than one set —
    # the item demand is the "real" requirement, the key is
    # incidental. We treat the `payload.items` and `payload.questItem`
    # rows as the "item side" (deduping the latter against the
    # former), then drop any key row for a task already covered by
    # the item side. When `item_is_key?` is true, the item-side rows
    # above were rewritten to `:key`, so this filtering still does
    # the right thing (it just deduplicates by task_id).
    item_task_ids = MapSet.new(item_rows, & &1.task_id)

    deduped_quest_items =
      Enum.reject(quest_item_rows, &MapSet.member?(item_task_ids, &1.task_id))

    item_side_task_ids =
      MapSet.union(item_task_ids, MapSet.new(deduped_quest_items, & &1.task_id))

    deduped_keys = Enum.reject(key_rows, &MapSet.member?(item_side_task_ids, &1.task_id))

    (item_rows ++ deduped_quest_items ++ deduped_keys)
    |> Enum.sort_by(& &1.task_name)
  end

  # True when *any* (non-blacklisted) quest objective references
  # this item via `payload.required_key_ids`. We use the same
  # data signal that surfaces keys in the new "Quest Items" scope
  # so the two stay in lockstep — if the scope filter would put
  # an item into the keys bucket, the per-item panel will phrase
  # it as a key too.
  defp item_used_as_key?(item_id_str, game_mode) when is_binary(item_id_str) do
    from(o in Objective,
      join: t in assoc(o, :task),
      where:
        fragment(
          "jsonb_typeof(?->'required_key_ids') = 'array' AND ? @> jsonb_build_array(?::text)",
          o.payload,
          o.payload["required_key_ids"],
          ^item_id_str
        ) and t.name not in ^@task_name_blacklist and t.game_mode == ^game_mode,
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  defp needed_by_hideout(item_id) do
    from(r in HideoutItemRequirement,
      join: l in assoc(r, :level),
      join: s in assoc(l, :station),
      where: r.item_id == ^item_id,
      select: %{
        station_name: s.name,
        station_slug: s.normalized_name,
        level: l.level,
        quantity: r.quantity
      },
      order_by: [asc: s.name, asc: l.level]
    )
    |> Repo.all()
  end

  # Tasks that grant this item as a reward, with the phase
  # (start = on-accept, finish = on-turn-in) so the UI can label.
  defp obtained_from_tasks(item_id, game_mode) do
    from(r in ItemReward,
      join: t in assoc(r, :task),
      where: r.item_id == ^item_id and t.game_mode == ^game_mode,
      select: %{
        task_id: t.id,
        task_name: t.name,
        quantity: r.quantity,
        phase: r.reward_phase
      },
      order_by: [asc: t.name]
    )
    |> Repo.all()
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
  defp unlocked_from_tasks(item_id, game_mode) do
    from(ou in OfferUnlock,
      join: t in assoc(ou, :task),
      join: tr in assoc(ou, :trader),
      where: ou.item_id == ^item_id and t.game_mode == ^game_mode,
      select: %{
        task_id: t.id,
        task_name: t.name,
        trader_name: tr.name,
        trader_slug: tr.normalized_name,
        level: ou.level,
        phase: ou.reward_phase
      },
      order_by: [asc: tr.name, asc: ou.level]
    )
    |> Repo.all()
  end

  # Barters whose `rewardItems` contains this item. We pull the full
  # required-items list per barter so the UI can render the cost
  # column without a follow-up query.
  defp obtained_from_barters(item_id, game_mode) do
    barter_query =
      from(rw in BarterRewardItem,
        join: b in assoc(rw, :barter),
        join: tr in assoc(b, :trader),
        left_join: tu in assoc(b, :task_unlock),
        # Trader the *unlock task* belongs to. Almost always the
        # same as `tr` (the barter's trader), but we pull it
        # separately so the "After completing X task Y" line is
        # accurate even on the rare cross-trader unlock.
        left_join: tut in assoc(tu, :trader),
        where: rw.item_id == ^item_id and b.game_mode == ^game_mode,
        order_by: [asc: tr.name, asc: b.level],
        select: %{
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

    barters = Repo.all(barter_query)
    barter_ids = Enum.map(barters, & &1.barter_id)

    required =
      if barter_ids == [] do
        %{}
      else
        from(rq in BarterRequiredItem,
          join: i in assoc(rq, :item),
          where: rq.barter_id in ^barter_ids,
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

    Enum.map(barters, fn b ->
      Map.put(b, :required, Map.get(required, b.barter_id, []))
    end)
  end

  # Same shape as `obtained_from_barters/1` but joining through
  # crafts → station_level → station so the UI can show
  # "Workbench level 2 (45m)".
  defp obtained_from_crafts(item_id) do
    craft_query =
      from(rw in CraftRewardItem,
        join: c in assoc(rw, :craft),
        join: l in assoc(c, :station_level),
        join: s in assoc(l, :station),
        left_join: tu in assoc(c, :task_unlock),
        # Trader who gives the unlock task. Crafts can be gated
        # by any trader's task (Mechanic ammunition crafts etc.),
        # so we surface this so the UI can phrase it as
        # "After completing <trader> task <task>".
        left_join: tut in assoc(tu, :trader),
        where: rw.item_id == ^item_id,
        order_by: [asc: s.name, asc: l.level],
        select: %{
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

    crafts = Repo.all(craft_query)
    craft_ids = Enum.map(crafts, & &1.craft_id)

    required =
      if craft_ids == [] do
        %{}
      else
        from(rq in CraftRequiredItem,
          join: i in assoc(rq, :item),
          where: rq.craft_id in ^craft_ids,
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

    Enum.map(crafts, fn c ->
      Map.put(c, :required, Map.get(required, c.craft_id, []))
    end)
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
  defp needed_for_crafts(item_id) do
    craft_query =
      from(rq in CraftRequiredItem,
        join: c in assoc(rq, :craft),
        join: l in assoc(c, :station_level),
        join: s in assoc(l, :station),
        left_join: tu in assoc(c, :task_unlock),
        # Same trader-of-the-unlock-task pull as `obtained_from_crafts/1`
        # so the "After completing <trader> task <task>" copy renders
        # identically in both directions.
        left_join: tut in assoc(tu, :trader),
        where: rq.item_id == ^item_id,
        order_by: [asc: s.name, asc: l.level],
        select: %{
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

    crafts = Repo.all(craft_query)
    craft_ids = Enum.map(crafts, & &1.craft_id)

    {required_by_craft, output_by_craft} =
      if craft_ids == [] do
        {%{}, %{}}
      else
        required =
          from(rq in CraftRequiredItem,
            join: i in assoc(rq, :item),
            where: rq.craft_id in ^craft_ids,
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

        # Primary reward per craft, keyed by craft_id. We order by
        # the row's id ascending and take the first row — the API
        # preserves declaration order, which matches the wiki's
        # "primary" output. Multi-output crafts are rare; if one
        # comes through this just picks whichever row was inserted
        # first, which is stable.
        output =
          from(rw in CraftRewardItem,
            join: i in assoc(rw, :item),
            where: rw.craft_id in ^craft_ids,
            order_by: [asc: rw.id],
            select: %{
              craft_id: rw.craft_id,
              item: i,
              quantity: rw.quantity
            }
          )
          |> Repo.all()
          |> Enum.reduce(%{}, fn row, acc ->
            # First-write-wins because the query is ordered ASC.
            Map.put_new(acc, row.craft_id, Map.delete(row, :craft_id))
          end)

        {required, output}
      end

    Enum.map(crafts, fn c ->
      c
      |> Map.put(:required, Map.get(required_by_craft, c.craft_id, []))
      |> Map.put(:output, Map.get(output_by_craft, c.craft_id))
    end)
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
  defp needed_for_barters(item_id, game_mode) do
    barter_query =
      from(rq in BarterRequiredItem,
        join: b in assoc(rq, :barter),
        join: tr in assoc(b, :trader),
        left_join: tu in assoc(b, :task_unlock),
        # Trader the *unlock task* belongs to. Same pattern as
        # `obtained_from_barters/1` — usually equal to the barter's
        # trader, but pulled separately for accuracy on cross-trader
        # unlocks.
        left_join: tut in assoc(tu, :trader),
        where: rq.item_id == ^item_id and b.game_mode == ^game_mode,
        order_by: [asc: tr.name, asc: b.level],
        select: %{
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

    barters = Repo.all(barter_query)
    barter_ids = Enum.map(barters, & &1.barter_id)

    {required_by_barter, output_by_barter} =
      if barter_ids == [] do
        {%{}, %{}}
      else
        required =
          from(rq in BarterRequiredItem,
            join: i in assoc(rq, :item),
            where: rq.barter_id in ^barter_ids,
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

        # Primary reward per barter, keyed by barter_id. Same
        # first-write-wins strategy as `needed_for_crafts/1` so
        # the row stays single-line for the common single-reward
        # case and is stable for the rare multi-reward one.
        output =
          from(rw in BarterRewardItem,
            join: i in assoc(rw, :item),
            where: rw.barter_id in ^barter_ids,
            order_by: [asc: rw.id],
            select: %{
              barter_id: rw.barter_id,
              item: i,
              quantity: rw.quantity
            }
          )
          |> Repo.all()
          |> Enum.reduce(%{}, fn row, acc ->
            Map.put_new(acc, row.barter_id, Map.delete(row, :barter_id))
          end)

        {required, output}
      end

    Enum.map(barters, fn b ->
      b
      |> Map.put(:required, Map.get(required_by_barter, b.barter_id, []))
      |> Map.put(:output, Map.get(output_by_barter, b.barter_id))
    end)
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
