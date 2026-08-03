defmodule EftBuddy.Items.Dataset do
  @moduledoc """
  The item catalogue held in memory, so the Items and Flea Market pages filter,
  sort and paginate without touching the database.

  ## Why these two pages needed something different

  Every other slow read in this app is a whole list that gets cached once and
  handed back. The Items and Flea Market reads cannot work that way: they take
  `:query`, `:offset`, `:favorite_slugs` and `:pmc_level`, so caching their
  *results* would mean one entry per user, per search string, per page —
  unbounded, and missed almost every time.

  They are also the pages where latency is felt most often. The search box fires
  on every debounced keystroke and infinite scroll fires on every page, so a
  ~250 ms round trip is not paid once on mount but continuously, while someone
  is typing.

  So the shape is inverted: cache the *dataset* once, shared by everybody, and
  do the per-request work in memory. Filtering 5,198 rows is CPU, and CPU is the
  resource this machine has spare — it sits at 2% while waiting on London.

  ## Three layers, deliberately separate

    * **Catalogue** — one ETS row per item, with `:category` preloaded and **no
      price overlay**. This is the expensive half (5,198 rows, ~38 MB, ~3 s to
      build) and it only changes when `ItemsSync` runs.

    * **Prices** — one row per `{item, mode}`, 10,118 in total and small.
      `PricesSync` rewrites these every ten minutes. Keeping them separate is
      what stops a price tick from throwing away the catalogue six times an hour.

    * **Indexes** — id lists and membership sets, described below.

  Rows are stored one per ETS object, never as a single list. A 38 MB list in
  one entry would be copied into the calling process on *every read* — which
  would make this slower than the 75 ms database it replaces, not faster. A page
  copies the ~40 rows it actually renders.

  ## Ordering and membership both come from Postgres

  This is the load-bearing decision. Neither is reproduced in Elixir.

  **Ordering** is collation-dependent. Measured against production, Postgres and
  `Enum.sort/1` disagree on the very first row of the default view: Postgres
  files `"Negotiation" room key` under N because its collation ignores leading
  punctuation, while byte order sorts it above `.300 Blackout AP`. Reproducing
  that faithfully would mean a Unicode collation library and a test suite for
  its edge cases. Instead the warm read comes back `ORDER BY`, and the resulting
  id list is stored. `Enum.filter/2` is stable, so every page derived from that
  list keeps the exact order SQL would have produced.

  **Membership** is worse. `:quest` scope is a three-arm SQL UNION over JSONB
  payload fields with a task-name blacklist; `:barter` subtracts a
  "contained item is redundant" set. Rewriting those in Elixir is the most
  likely place in this codebase to introduce a divergence nobody notices. So
  Postgres computes each scope's id set — using the very same `apply_scope/3`
  the SQL path uses, via `EftBuddy.Items.scope_ids/2` — and this module only
  holds the answer.

  What *is* done here is the part that is genuinely simple and genuinely
  per-request: substring search, set membership, favourites-first partitioning,
  and slicing.

  ## Failing back rather than failing

  `ready?/0` gates every read. It is false before the first build, during a
  rebuild, and once a layer is older than its refresh cadence allows. In all
  three cases callers fall through to the original SQL path.

  That last case matters most: if warming breaks, this layer would otherwise
  serve a snapshot of the catalogue forever, silently. Staleness bounds turn
  that into "quietly slower" instead of "quietly wrong", which is the right way
  round.
  """

  use GenServer

  require Logger

  alias EftBuddy.Items

  @rows :eft_buddy_dataset_rows
  @prices :eft_buddy_dataset_prices
  @meta :eft_buddy_dataset_meta

  # The sorts the Items page offers. Each is one `ORDER BY` at build time.
  @sorts [:default, :name_asc, :name_desc, :class_asc, :class_desc]

  # The structured scope tabs. `:all` needs no set (it is the whole catalogue)
  # and `:watchlist` is per-operator, so it is a favourites filter rather than a
  # scope set.
  @scopes [:hideout, :quest, :barter, :craft]

  @ui_modes [:pvp, :pve]

  # Staleness bounds, past which a layer stops being served and reads fall back
  # to SQL. Sized well above each layer's own refresh cadence so a normal cycle
  # never trips them: the catalogue is rebuilt by ItemsSync (6h) and prices by
  # PricesSync (10 min).
  @catalog_max_age_ms 12 * 60 * 60 * 1_000
  @prices_max_age_ms 60 * 60 * 1_000

  # ── Lifecycle ──────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    for table <- [@rows, @prices, @meta] do
      :ets.new(table, [:set, :named_table, :public, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @doc """
  Whether reads may be served from memory for `game_mode`.

  False before the first build, while a rebuild is in flight, and once either
  layer is past its staleness bound. Callers fall back to SQL in every case, so
  a false here costs latency and never correctness.
  """
  def ready?(game_mode) do
    enabled?() and not building?() and
      fresh?(:catalog_built_at, @catalog_max_age_ms) and
      fresh?({:prices_built_at, db_mode(game_mode)}, @prices_max_age_ms)
  end

  # Coerced to a real boolean rather than returned raw. `Application.get_env/3`'s
  # default only applies when the key is ABSENT, so a key explicitly set to nil
  # returns nil — and `ready?/1` chains this through `and`, which raises on a
  # non-boolean rather than treating it as false. A config mistake should
  # degrade this layer to "off", never take a page down.
  def enabled?, do: !!Application.get_env(:eft_buddy, :item_dataset_enabled, false)

  # ── Building ───────────────────────────────────────────

  @doc """
  Rebuild the catalogue, the order indexes and the scope sets.

  Registered as a warm spec against every syncer that feeds a scope set, so it
  runs on the server rather than being triggered by a visitor's request.
  """
  def refresh_catalog do
    if enabled?() do
      build(fn ->
        rows = Items.catalog_rows()

        :ets.delete_all_objects(@rows)

        # Prefolded search fields are stored ALONGSIDE the struct rather than
        # computed per request: a keystroke would otherwise re-downcase 5,198
        # names and short names, twice, on every debounce tick.
        :ets.insert(
          @rows,
          Enum.map(rows, fn item ->
            {item.id, item, fold(item.name), fold(item.short_name)}
          end)
        )

        for sort <- @sorts do
          :ets.insert(@meta, {{:order, sort}, Items.ordered_ids(sort)})
        end

        for scope <- @scopes, mode <- @ui_modes do
          ids = scope |> Items.scope_ids(mode) |> MapSet.new()
          :ets.insert(@meta, {{:scope, scope, db_mode(mode)}, ids})
        end

        :ets.insert(@meta, {:catalog_built_at, now_ms()})
        Logger.info("[Dataset] catalogue rebuilt: #{length(rows)} items")
      end)
    end

    :ok
  end

  @doc """
  Rebuild the price layer and the flea order index for every mode.

  Runs on `PricesSync`, every ten minutes, and deliberately does NOT touch the
  catalogue — that separation is the reason a price tick costs one small query
  instead of a three-second catalogue reload.
  """
  def refresh_prices do
    if enabled?() do
      build(fn ->
        :ets.delete_all_objects(@prices)

        for mode <- @ui_modes do
          db = db_mode(mode)

          :ets.insert(
            @prices,
            Enum.map(Items.price_rows(mode), fn p -> {{p.item_id, db}, p} end)
          )

          :ets.insert(@meta, {{:flea_order, db}, Items.flea_ordered_ids(mode)})
          :ets.insert(@meta, {{:prices_built_at, db}, now_ms()})
        end

        Logger.info("[Dataset] price layer rebuilt")
      end)
    end

    :ok
  end

  @doc "Drop everything. For tests and for a remote console."
  def clear do
    for table <- [@rows, @prices, @meta] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc false
  def stats do
    %{
      enabled: enabled?(),
      building: building?(),
      items: table_size(@rows),
      price_rows: table_size(@prices),
      catalog_age_ms: age_ms(:catalog_built_at),
      memory_bytes: Enum.sum(for t <- [@rows, @prices, @meta], do: table_memory(t))
    }
  end

  # A rebuild empties and refills its table, so readers must not see the gap.
  # Flagging instead of double-buffering costs a few seconds of SQL fallback and
  # saves holding two copies of a 38MB catalogue; `try/after` guarantees the flag
  # clears even if the build raises, since a stuck flag would mean permanent
  # fallback.
  defp build(fun) do
    :ets.insert(@meta, {:building, true})

    try do
      fun.()
    after
      :ets.insert(@meta, {:building, false})
    end
  end

  # ── Reads ──────────────────────────────────────────────

  @doc """
  In-memory equivalent of `EftBuddy.Items.list_all_items/1`.

  The order comes from a precomputed index, so filtering it (stable) and slicing
  it reproduces SQL's `ORDER BY … LIMIT … OFFSET` exactly.
  """
  def list_all_items(opts) do
    mode = opts |> Keyword.get(:game_mode) |> db_mode()
    scope = Keyword.get(opts, :scope, :all)
    favorite_slugs = clean_slugs(Keyword.get(opts, :favorite_slugs, []))

    meta({:order, Keyword.get(opts, :sort, :default)}, [])
    |> rows()
    |> filter_scope(scope, mode, favorite_slugs)
    |> filter_search(Keyword.get(opts, :query, ""))
    |> filter_categories(Keyword.get(opts, :category_names, []))
    |> favorites_first(scope, favorite_slugs)
    |> paginate(Keyword.get(opts, :offset, 0), Keyword.get(opts, :limit, 40))
    |> Enum.map(&materialize(&1, mode))
  end

  @doc "In-memory equivalent of `EftBuddy.Items.list_flea_market_items/1`."
  def list_flea_market_items(opts) do
    mode = opts |> Keyword.get(:game_mode) |> db_mode()
    status = Keyword.get(opts, :flea_status, :all)
    favorite_slugs = clean_slugs(Keyword.get(opts, :favorite_slugs, []))

    opts
    |> flea_base(mode)
    |> filter_flea_view(status, Keyword.get(opts, :pmc_level, 1), favorite_slugs)
    |> flea_favorites_first(status, favorite_slugs)
    |> paginate(Keyword.get(opts, :offset, 0), Keyword.get(opts, :limit, 40))
    |> Enum.map(&materialize(&1, mode))
  end

  @doc "In-memory equivalent of `EftBuddy.Items.flea_market_status_counts/1`."
  def flea_market_status_counts(opts) do
    mode = opts |> Keyword.get(:game_mode) |> db_mode()
    pmc_level = Keyword.get(opts, :pmc_level, 1)
    favorite_slugs = clean_slugs(Keyword.get(opts, :favorite_slugs, []))
    floor = Items.flea_unlock_level()

    base = flea_base(opts, mode)
    total = length(base)

    buyable = Enum.count(base, fn {_id, item, _n, _s} -> buyable?(item, pmc_level, floor) end)

    watchlist =
      Enum.count(base, fn {_id, item, _n, _s} -> item.normalized_name in favorite_slugs end)

    %{all: total, buyable: buyable, locked: total - buyable, watchlist: watchlist}
  end

  # The flea listing and the status counts share this, exactly as the SQL path
  # shares `flea_base_query/1` — otherwise a badge could disagree with the tab it
  # labels.
  defp flea_base(opts, mode) do
    meta({:flea_order, mode}, [])
    |> rows()
    |> filter_search(Keyword.get(opts, :query, ""))
    |> filter_categories(Keyword.get(opts, :category_names, []))
  end

  # ── Filters ────────────────────────────────────────────

  # Resolve an ordered id list to ordered rows, dropping ids with no row. The
  # drop matters: the order index and the catalogue are written in the same
  # build, but a price index written ten minutes later can name an item the
  # catalogue no longer has.
  defp rows(ids) do
    Enum.flat_map(ids, fn id ->
      case :ets.lookup(@rows, id) do
        [row] -> [row]
        [] -> []
      end
    end)
  end

  defp filter_scope(rows, :all, _mode, _favorites), do: rows

  # `:watchlist` is not a catalogue subset — it cuts across every scope — so it
  # is a favourites filter, mirroring `apply_item_scope/4`.
  defp filter_scope(rows, :watchlist, _mode, favorites) do
    Enum.filter(rows, fn {_id, item, _n, _s} -> item.normalized_name in favorites end)
  end

  defp filter_scope(rows, scope, mode, _favorites) do
    case :ets.lookup(@meta, {:scope, scope, mode}) do
      # Unknown scopes show everything rather than silently returning nothing,
      # matching the SQL path's catch-all clause.
      [] -> rows
      [{_key, ids}] -> Enum.filter(rows, fn {id, _item, _n, _s} -> MapSet.member?(ids, id) end)
    end
  end

  defp filter_search(rows, query) do
    case Items.search_tokens(query) do
      [] ->
        rows

      tokens ->
        folded = Enum.map(tokens, &fold/1)

        # AND across tokens, OR across the two fields — the same shape as the
        # SQL, which ANDs a `ilike(name) or ilike(short_name)` per token.
        #
        # The two fields are matched separately rather than against a
        # concatenation, so a token cannot match by spanning the boundary
        # between a name and a short name.
        Enum.filter(rows, fn {_id, _item, name, short} ->
          Enum.all?(folded, fn t ->
            String.contains?(name, t) or String.contains?(short, t)
          end)
        end)
    end
  end

  defp filter_categories(rows, names) when names in [nil, []], do: rows

  defp filter_categories(rows, names) do
    Enum.filter(rows, fn {_id, item, _n, _s} ->
      case item.category do
        %{name: name} -> name in names
        _ -> false
      end
    end)
  end

  defp filter_flea_view(rows, :watchlist, _pmc_level, favorites) do
    Enum.filter(rows, fn {_id, item, _n, _s} -> item.normalized_name in favorites end)
  end

  defp filter_flea_view(rows, :buyable, pmc_level, _favorites) do
    floor = Items.flea_unlock_level()
    Enum.filter(rows, fn {_id, item, _n, _s} -> buyable?(item, pmc_level, floor) end)
  end

  defp filter_flea_view(rows, :locked, pmc_level, _favorites) do
    floor = Items.flea_unlock_level()
    Enum.reject(rows, fn {_id, item, _n, _s} -> buyable?(item, pmc_level, floor) end)
  end

  defp filter_flea_view(rows, _status, _pmc_level, _favorites), do: rows

  # `effective_flea_level/2` already mirrors the SQL's
  # `GREATEST(floor, COALESCE(item, category, floor))`, so the lock split is one
  # shared definition rather than two that can drift.
  defp buyable?(item, pmc_level, floor) do
    Items.effective_flea_level(item, floor) <= pmc_level
  end

  # ── Ordering ───────────────────────────────────────────

  # Float favourites to the top of a non-watchlist listing. `Enum.split_with/2`
  # preserves relative order within each part, which is exactly what SQL's
  # `ORDER BY (slug = ANY($1)) DESC, <the rest>` does — the favourite flag is the
  # primary key and the existing order breaks ties inside each group.
  defp favorites_first(rows, :watchlist, _favorites), do: rows
  defp favorites_first(rows, _scope, []), do: rows

  defp favorites_first(rows, _scope, favorites) do
    {favoured, rest} =
      Enum.split_with(rows, fn {_id, item, _n, _s} -> item.normalized_name in favorites end)

    favoured ++ rest
  end

  defp flea_favorites_first(rows, :watchlist, _favorites), do: rows
  defp flea_favorites_first(rows, _status, []), do: rows

  defp flea_favorites_first(rows, _status, favorites) do
    {favoured, rest} =
      Enum.split_with(rows, fn {_id, item, _n, _s} -> item.normalized_name in favorites end)

    favoured ++ rest
  end

  defp paginate(rows, offset, limit), do: rows |> Enum.drop(offset) |> Enum.take(limit)

  # Only the page's rows get a price overlay — roughly 40 per request rather
  # than 5,198.
  defp materialize({id, item, _name, _short}, mode) do
    price =
      case :ets.lookup(@prices, {id, mode}) do
        [{_key, p}] -> p
        [] -> nil
      end

    Items.overlay_price(item, price)
  end

  # ── Helpers ────────────────────────────────────────────

  defp fold(nil), do: ""
  defp fold(text) when is_binary(text), do: String.downcase(text)

  defp clean_slugs(slugs) when is_list(slugs),
    do: Enum.filter(slugs, &(is_binary(&1) and &1 != ""))

  defp clean_slugs(_), do: []

  defp db_mode(mode), do: EftBuddy.GameMode.to_db(mode)

  defp meta(key, default) do
    case :ets.whereis(@meta) do
      :undefined ->
        default

      _ ->
        case :ets.lookup(@meta, key) do
          [{^key, value}] -> value
          [] -> default
        end
    end
  end

  defp building?, do: meta(:building, false)

  defp fresh?(key, max_age_ms) do
    case meta(key, nil) do
      nil -> false
      built_at -> now_ms() - built_at < max_age_ms
    end
  end

  defp age_ms(key) do
    case meta(key, nil) do
      nil -> nil
      built_at -> now_ms() - built_at
    end
  end

  defp table_size(table) do
    if :ets.whereis(table) != :undefined, do: :ets.info(table, :size), else: 0
  end

  defp table_memory(table) do
    if :ets.whereis(table) != :undefined,
      do: :ets.info(table, :memory) * :erlang.system_info(:wordsize),
      else: 0
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
