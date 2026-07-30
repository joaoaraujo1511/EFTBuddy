defmodule EftBuddy.Maps.Sync do
  @moduledoc """
  Syncs maps and their sub-entities — bosses, extracts, transits,
  locks, hazards and access keys — from the tarkov.dev JSON API (via
  `EftBuddy.TarkovApi`) into the local database, plus the interactive-map
  `svg_path` from
  tarkov.dev's `maps.json` (the GraphQL API exposes no map imagery).

  Like `EftBuddy.Tasks.Sync`, this module is **not** a `GenServer` and
  is **not** scheduled. Maps change only on wipes / patches, so the
  cold-start `EftBuddy.Sync.Bootstrap` runs it once on boot and a dev
  can re-run it on demand from IEx:

      EftBuddy.Maps.Sync.run()

  It must run **after** `EftBuddy.Items.Sync.run_items/0` because access
  keys, lock keys and item-gated extracts resolve their `*_item_id`
  foreign keys against the `items` table. It has no other dependencies.

  The sync is idempotent: every run upserts the full snapshot returned
  by the API (keying maps on the stable `normalized_name` slug so their
  UUIDs — and thus `tasks.map_id` — stay stable even when the API rotates
  a map's `external_id`) and replaces every map's sub-entity rows. Maps that disappear from the API are removed, and the
  `on_delete: :delete_all` FKs cascade their sub-entities away.

  ## Aggregation

  The API returns one entry per physical position for hazards and locks.
  We collapse identical entries into one row carrying a `count`, keeping
  the first occurrence's `position { x y z }` as a representative pin for
  the in-app map viewer. Extracts and transits are one row each and keep
  their exact position.

  ## Partial responses

  The maps query routinely returns a top-level `errors` array *alongside*
  a full `data` payload (e.g. a transit whose destination map id isn't
  in the snapshot). Those are non-fatal: we use the data when
  `data.maps` is a list and only surface the errors as a warning count.
  """

  use GenServer

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  alias EftBuddy.Maps.{
    AccessKey,
    Boss,
    Extract,
    Hazard,
    Lock,
    LootContainer,
    Spawn,
    StationaryWeapon,
    Switch,
    Transit,
    Variant
  }

  # `EftBuddy.Maps.Map` shadows the stdlib `Map` module we lean on for
  # the API-payload maps, so alias it as `GameMap` (same convention as
  # `Tasks.Sync`).
  alias EftBuddy.Maps.Map, as: GameMap

  # tarkov.dev's frontend map metadata. The data API has no map
  # imagery, so the interactive-map SVG URLs live here. Fetched
  # best-effort each run; a failure just leaves `svg_path` nil.
  @maps_json_url "https://raw.githubusercontent.com/the-hideout/tarkov-dev/main/src/data/maps.json"
  @http_timeout 60_000
  @lock_id {__MODULE__, :running}

  # ── Schedule ───────────────────────────────────────────
  #
  # See `EftBuddy.Ammo.Sync`'s schedule section for the full reasoning; the
  # modules are deliberately identical here apart from the slot.

  @default_interval 24 * 60 * 60 * 1_000

  # First slot in the daily cycle: maps +20 → hideout +30 → ammo +40 → armor
  # +50 → tasks +60. Maps leads because `tasks.map_id` resolves against it, so
  # this ordering mirrors Bootstrap's FK sequence inside each cycle.
  @stagger 20 * 60 * 1_000

  # A FULL INTERVAL from `:bootstrap_complete`, not zero: Bootstrap runs this
  # sync itself as part of the cold start, so it has already happened by the
  # time the cast arrives. (The wiki scrapers use 0 because Bootstrap only
  # *releases* them.)
  @bootstrap_offset @default_interval + @stagger

  # Short fallback for when the bootstrap signal never arrives — in that case
  # this sync has NOT run and the table may be empty.
  @fallback_delay 15 * 60 * 1_000 + @stagger

  @doc false
  # Public so `EftBuddy.Sync.Freshness` can assert its staleness budget covers
  # this cadence rather than trusting a comment to keep the two in step.
  def interval_ms, do: @default_interval

  @doc false
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.info("[#{prefix()}] Another node already runs the maps sync; staying idle here.")
        :ignore
    end
  end

  @doc "Trigger a sync asynchronously (e.g. from IEx)."
  def sync_now, do: GenServer.cast({:global, __MODULE__}, :sync_now)

  # ── Server ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    first = Keyword.get(opts, :first_run_delay, @fallback_delay)
    timer = Process.send_after(self(), :sync, first + jitter(first))
    {:ok, %{interval: interval, timer: timer}}
  end

  @impl true
  def handle_info(:sync, %{interval: interval} = state) do
    safe_run()
    timer = Process.send_after(self(), :sync, interval + jitter(interval))
    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_cast(:bootstrap_complete, state) do
    {:noreply, arm_first_run(state, @bootstrap_offset)}
  end

  def handle_cast(:sync_now, state) do
    safe_run()
    {:noreply, state}
  end

  defp arm_first_run(state, offset) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :sync, offset + jitter(offset))
    %{state | timer: timer}
  end

  defp safe_run do
    case run() do
      {:ok, summary} ->
        Logger.info("[#{prefix()}] done: #{inspect(summary)}")
        {:ok, summary}

      {:error, :already_running} ->
        Logger.info("[#{prefix()}] skipped: another maps sync is already running")
        {:error, :already_running}

      {:error, reason} ->
        Logger.warning("[#{prefix()}] run ended early: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  # ±10%, so several nodes (or several restarts) never align on one instant.
  defp jitter(ms) when is_integer(ms) and ms > 0, do: :rand.uniform(div(ms, 10) + 1)
  defp jitter(_), do: 0

  # ── Public API ─────────────────────────────────────────

  @doc """
  Run a full sync of maps. Synchronous: blocks until done.

  Returns `{:ok, counts}` on success or `{:error, reason}`.
  Returns `{:error, :already_running}` if another maps sync is in
  progress on any node in the cluster.
  """
  def run do
    case acquire_lock() do
      true ->
        try do
          do_run()
        after
          release_lock()
        end

      false ->
        Logger.warning("[#{prefix()}] Skipped: another sync is already running.")
        {:error, :already_running}
    end
  end

  defp acquire_lock do
    :global.set_lock(@lock_id, [node() | Node.list()], 0)
  end

  defp release_lock do
    :global.del_lock(@lock_id, [node() | Node.list()])
  end

  defp do_run do
    Reporter.with_run("MapsSync", fn ->
      case fetch_maps() do
        {:ok, raw_maps} ->
          maps = sanitize(raw_maps)
          media = fetch_map_media()

          case upsert_all(maps, media) do
            {:ok, counts} ->
              {:ok, counts}

            {:error, _, reason, _} ->
              Logger.error("[#{prefix()}] Multi failed: #{Reporter.describe_error(reason)}")
              {:error, reason}

            {:error, reason} ->
              Logger.error("[#{prefix()}] Error: #{Reporter.describe_error(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("[#{prefix()}] Fetch failed: #{Reporter.describe_error(reason)}")
          {:error, reason}
      end
    end)
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] Crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  # ── Fetch ──────────────────────────────────────────────

  defp fetch_maps do
    EftBuddy.TarkovApi.maps()
  end

  # Best-effort fetch of tarkov.dev's frontend `maps.json` to recover the
  # map imagery per map (keyed by normalizedName): the interactive SVG
  # URL plus the flat 2D / 3D static renders. The GraphQL/JSON data API
  # has no imagery, so this is the source of `svg_path` and
  # `image_variants`. Any failure (network, shape drift) degrades to an
  # empty map and the sync proceeds without images — the page just shows
  # no viewer.
  defp fetch_map_media do
    case Req.get(@maps_json_url,
           receive_timeout: @http_timeout,
           connect_options: [timeout: 5_000],
           retry: &retry_transient?/2,
           max_retries: 2,
           headers: [{"user-agent", "EftBuddy/1.0 (+maps-sync)"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        # raw.githubusercontent serves the file as text/plain, so Req
        # doesn't auto-decode it — handle both decoded and raw bodies.
        case decode_groups(body) do
          [] ->
            Reporter.silent_warn(
              "[#{prefix()}] maps.json returned no usable groups; continuing without map images"
            )

            %{}

          groups ->
            build_map_media(groups)
        end

      other ->
        Reporter.silent_warn(
          "[#{prefix()}] maps.json fetch failed (#{inspect(elem_status(other))}); " <>
            "continuing without map images"
        )

        %{}
    end
  rescue
    e ->
      Reporter.silent_warn(
        "[#{prefix()}] maps.json fetch crashed (#{Exception.message(e)}); " <>
          "continuing without map images"
      )

      %{}
  end

  defp decode_groups(body) when is_list(body), do: body

  defp decode_groups(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_groups(_), do: []

  # tarkov.dev serves the flat 2D / 3D map renders as JPGs under this
  # path, keyed by the render's `key` (e.g. `customs-3d`). CSP
  # `img-src https:` allows them as plain <img> sources in the viewer.
  @image_base "https://tarkov.dev/maps"

  # Build %{normalized_name => %{svg_path:, image_variants:, rendering:}}
  # from the maps.json groups. `svg_path` keeps only the interactive SVG
  # URL (tile-based interactive maps carry no SVG). `image_variants`
  # collects every flat 2D / 3D render, in maps.json order (base first),
  # so the viewer can offer a mode toggle and loop through variants.
  # `rendering` is the projection config the interactive viewer needs.
  defp build_map_media(groups) do
    Enum.reduce(groups, %{}, fn group, acc ->
      slug = group["normalizedName"]
      maps = group["maps"] || []

      if is_binary(slug) do
        Map.put(acc, slug, %{
          svg_path: interactive_svg_path(maps),
          image_variants: image_variants(maps),
          rendering: rendering_config(maps)
        })
      else
        acc
      end
    end)
  end

  # ── Rendering config ───────────────────────────────────

  # The projection config for the map's interactive base. This used to be
  # hand-copied into `EftBuddy.Maps.Assets` and had drifted: The Lab lost its
  # "Technical" floor, Customs its "4th Floor", Reserve four upper floors, and
  # every map's room labels were dropped. It is read live from the same
  # maps.json we already fetch, so upstream fixes arrive on the next sync.
  #
  # Returns `%{}` when the group has no interactive entry (the map then has no
  # in-app viewer and falls back to its flat 2D/3D renders).
  defp rendering_config(maps) do
    case Enum.find(maps, &(&1["projection"] == "interactive")) do
      nil ->
        %{}

      m ->
        %{
          projection: base_projection(m),
          transform: float_list(m["transform"]),
          coordinate_rotation: to_float(m["coordinateRotation"]),
          bounds: bounds_pair(m["bounds"]),
          svg_bounds: bounds_pair(m["svgBounds"]),
          min_zoom: m["minZoom"],
          max_zoom: m["maxZoom"],
          tile_size: m["tileSize"],
          tile_path: m["tilePath"],
          height_range: float_list(m["heightRange"]),
          layers: layer_config(m["layers"]),
          labels: label_config(m["labels"]),
          image_author: m["author"],
          image_author_link: m["authorLink"]
        }
    end
  end

  # Prefer SVG: 7 of the 10 SVG maps *also* publish a raster tile base, but we
  # self-host the SVGs (same-origin, hand-drawn, CC BY-NC-SA) so they win.
  # Only The Lab, The Labyrinth and Icebreaker are tile-only.
  defp base_projection(%{"svgPath" => svg}) when is_binary(svg), do: "svg"
  defp base_projection(%{"tilePath" => tile}) when is_binary(tile), do: "tile"
  defp base_projection(_), do: nil

  # Toggleable floors. Each carries either an `svgLayer` (a `<g>` id to
  # highlight) or a `tileUrl` (its own tile pyramid) — and the two mix on one
  # map: Customs' 4th floor and Reserve's upper floors are tile overlays on an
  # SVG base. `id` is upstream's `svgLayer` when present, else a slug of the
  # name, so tile floors get a stable handle without hand-maintained ids.
  defp layer_config(layers) when is_list(layers) do
    for l <- layers, is_binary(l["name"]) do
      %{
        "name" => l["name"],
        "id" => l["svgLayer"] || slugify(l["name"]),
        "svgLayer" => l["svgLayer"],
        "tileUrl" => l["tilePath"],
        "extents" => extent_config(l["extents"])
      }
    end
  end

  defp layer_config(_), do: []

  # Height (and optional x/z rectangle) ranges that bind a marker to a floor.
  # `bounds` stays as-is: it is a list of game-coordinate rectangles, or absent
  # when the extent is height-only.
  defp extent_config(extents) when is_list(extents) do
    for e <- extents, is_list(e["height"]) do
      %{"height" => float_list(e["height"]), "bounds" => e["bounds"]}
    end
  end

  defp extent_config(_), do: []

  # Room / area names drawn on the map. `top` / `bottom` are the height band the
  # label belongs to, so floor selection can filter them.
  defp label_config(labels) when is_list(labels) do
    for l <- labels, is_binary(l["text"]), is_list(l["position"]) do
      %{
        "position" => float_list(l["position"]),
        "text" => l["text"],
        "top" => to_float(l["top"]),
        "bottom" => to_float(l["bottom"]),
        "size" => l["size"]
      }
    end
  end

  defp label_config(_), do: []

  # `[[x1, z1], [x2, z2]]`, or nil when absent / malformed. Postgres stores this
  # as float8[][], which requires both rows to be the same length.
  defp bounds_pair(bounds) when is_list(bounds) do
    rows = for row <- bounds, is_list(row), do: float_list(row)

    case rows do
      [[_, _], [_, _]] -> rows
      _ -> nil
    end
  end

  defp bounds_pair(_), do: nil

  defp float_list(list) when is_list(list) do
    for v <- list, is_number(v), do: to_float(v)
  end

  defp float_list(_), do: nil

  defp interactive_svg_path(maps) do
    Enum.find_value(maps, fn m ->
      if m["projection"] == "interactive" and is_binary(m["svgPath"]),
        do: m["svgPath"]
    end)
  end

  # Group the flat renders by projection ("2d" / "3d"), dropping empties.
  @doc false
  def image_variants(maps) do
    maps
    |> Enum.filter(&(&1["projection"] in ["2D", "3D"] and is_binary(&1["key"])))
    |> Enum.group_by(&String.downcase(&1["projection"]), &variant/1)
    |> Map.reject(fn {_k, v} -> v == [] end)
  end

  # Each flat render is separately authored — a map's 2D and 3D are usually by
  # different people, and neither is the author of its interactive base. The
  # link rides along so the viewer's per-render credit can reach them; it is
  # `nil` for the one upstream entry (Lighthouse's 2D, "Shebuka & Jindouz") that
  # names an author without giving one.
  defp variant(%{"key" => key, "projection" => projection} = m) do
    %{
      "key" => key,
      "url" => "#{@image_base}/#{key}.jpg",
      "label" => variant_label(m, key, projection),
      "author" => m["author"],
      "author_link" => m["authorLink"]
    }
  end

  # Human label for a render's variant-cycle button. Prefer the explicit
  # `specific` field ("Resort", "Tunnels", …); else derive from any key
  # suffix past the base `<slug>-2d` / `<slug>-3d` (e.g.
  # "customs-3d-dorms" → "Dorms"); else fall back to the projection name.
  defp variant_label(%{"specific" => specific}, _key, _projection) when is_binary(specific),
    do: specific

  defp variant_label(_m, key, projection) do
    marker = "-" <> String.downcase(projection)

    case String.split(key, marker <> "-", parts: 2) do
      [_base, suffix] when suffix != "" ->
        suffix
        |> String.split(~r/[-_]/, trim: true)
        |> Enum.map_join(" ", &String.capitalize/1)

      _ ->
        String.upcase(projection)
    end
  end

  defp elem_status({:ok, %{status: s}}), do: s
  defp elem_status({:error, reason}), do: reason

  # ── Sanitize ───────────────────────────────────────────

  # ── Map identity ───────────────────────────────────────
  #
  # Three separate mechanisms, deliberately kept apart. The old `@merge_into`
  # conflated them and got Ground Zero wrong as a result.

  # Locations where a *sibling* payload is the real source of truth. The
  # `ground-zero` row takes all of its gameplay data from `ground-zero-21`;
  # base Ground Zero (the level <=20 bracket, which has no bosses at all) is
  # discarded.
  #
  # The slug stays `ground-zero` because the vendored SVG filename, the
  # maps.json rendering group and the public URL are all keyed on it and none
  # has a `-21` form — renaming would 404 the SVG and lose the projection
  # config. Only the gameplay side flips.
  @canonical_source %{"ground-zero" => "ground-zero-21"}

  # Locations with more than one playable raid. Both are kept and combined onto
  # one card, each contributing a `map_variants` row with its own raid duration,
  # player count and boss entries (Factory: Tagilla 50% by day, 75% at night).
  @variants %{
    "night-factory" => %{parent: "factory", kind: "night", label: "Night"}
  }

  # Label for the parent's own (base) variant when a map has siblings, so the
  # UI can say "Day" rather than leaving the default raid unnamed.
  @base_labels %{"factory" => "Day"}

  # Locations that must never become a map row at all. The Ground Zero tutorial
  # is a scripted onboarding instance, not a playable raid.
  @drop_slugs ~w(ground-zero-tutorial)

  # Private keys used to carry variant payloads through the pipeline attached to
  # their parent, so a variant never becomes its own map row but its bosses and
  # raid parameters still reach the DB.
  @variant_key "__variants"
  @variant_spec_key "__variant_spec"

  defp sanitize(maps) do
    maps
    |> Enum.filter(&has_required_fields?/1)
    |> Elixir.Map.new(&{&1["normalizedName"], &1})
    |> apply_canonical_sources()
    |> attach_variants()
    |> Elixir.Map.values()
    |> Enum.reject(&(&1["normalizedName"] in @drop_slugs))
  end

  # Replace a canonical slug's payload wholesale with its source sibling's,
  # rewriting the slug so it lands on the canonical row. The source entry is
  # removed so it never syncs as a map of its own.
  defp apply_canonical_sources(by_slug) do
    Enum.reduce(@canonical_source, by_slug, fn {canonical, source}, acc ->
      case {Elixir.Map.get(acc, canonical), Elixir.Map.get(acc, source)} do
        {%{} = canonical_payload, %{} = source_payload} ->
          acc
          |> Elixir.Map.delete(source)
          |> Elixir.Map.put(canonical, rebase(source_payload, canonical_payload, canonical))

        _ ->
          acc
      end
    end)
  end

  # Take everything from the source sibling but keep the canonical row's
  # *identity*: its `id`, `normalizedName`, `name` and `description`.
  #
  # `normalizedName` has to stay because the vendored SVG filename, the
  # maps.json rendering group and the public URL are all keyed on it, and none
  # has a `-21` form. `id` has to stay because it becomes `maps.external_id`,
  # which `EftBuddy.Tasks.Sync` upserts against — and tasks overwhelmingly
  # reference the base map (7 primary + 32 objective references, vs 1 + 37 for
  # the sibling, which `EftBuddy.Maps.alias_slug/1` redirects here anyway).
  #
  # `name` and `description` stay because the sibling's are level-bracketed
  # ("Ground Zero 21+"), and the map is not a different place — the bracket is
  # already visible through `min/max_player_level`.
  @doc false
  def rebase(source_payload, canonical_payload, canonical_slug) do
    source_payload
    |> Elixir.Map.put("id", canonical_payload["id"])
    |> Elixir.Map.put("normalizedName", canonical_slug)
    |> Elixir.Map.put("name", canonical_payload["name"] || source_payload["name"])
    |> Elixir.Map.put(
      "description",
      canonical_payload["description"] || source_payload["description"]
    )
  end

  # Attach each variant payload to its parent and drop it as a top-level map.
  #
  # Only `enemies` is merged onto the parent (unioned, so Factory's header lists
  # the night-only cultists). Everything spatial is deliberately left alone:
  # parent and variant extracts / locks / hazards are identical when compared by
  # name + position but carry per-map-instance `id` hashes, so unioning them by
  # id would double every extract and lock on the map.
  defp attach_variants(by_slug) do
    Enum.reduce(@variants, by_slug, fn {slug, spec}, acc ->
      with %{} = variant <- Elixir.Map.get(acc, slug),
           %{} = parent <- Elixir.Map.get(acc, spec.parent) do
        tagged = Elixir.Map.put(variant, @variant_spec_key, spec)

        merged =
          parent
          |> Elixir.Map.put(@variant_key, List.wrap(parent[@variant_key]) ++ [tagged])
          |> Elixir.Map.put(
            "enemies",
            Enum.uniq(List.wrap(parent["enemies"]) ++ List.wrap(variant["enemies"]))
          )

        acc
        |> Elixir.Map.delete(slug)
        |> Elixir.Map.put(spec.parent, merged)
      else
        _ -> acc
      end
    end)
  end

  # Every raid variant of a map, base first: `{payload, spec}` pairs. The base
  # variant is the map payload itself, so the read side never has to special-case
  # maps with and without siblings.
  defp variant_payloads(m) do
    base_spec = %{
      kind: "base",
      label: Elixir.Map.get(@base_labels, m["normalizedName"]),
      base: true
    }

    extra =
      m
      |> Elixir.Map.get(@variant_key)
      |> List.wrap()
      |> Enum.map(fn v -> {v, Elixir.Map.get(v, @variant_spec_key, %{kind: "base"})} end)

    [{m, base_spec} | extra]
  end

  defp has_required_fields?(%{"id" => id, "name" => name, "normalizedName" => slug})
       when is_binary(id) and is_binary(name) and is_binary(slug),
       do: true

  defp has_required_fields?(_), do: false

  # ── Pipeline ───────────────────────────────────────────

  defp upsert_all(maps, media) do
    Ecto.Multi.new()
    # Item id map (FK target — items already populated by Items.Sync).
    |> Ecto.Multi.run(:item_id_map, fn repo, _ ->
      {:ok, fetch_external_id_map(repo, Item)}
    end)
    # 1. Maps themselves (keyed on the stable normalized_name slug so a
    #    map's UUID survives even when the API rotates its external id —
    #    which otherwise collides on the normalized_name unique index).
    |> Ecto.Multi.run(:upsert_maps, fn repo, _ -> upsert_maps(repo, maps, media) end)
    |> Ecto.Multi.run(:map_id_map, fn repo, _ ->
      {:ok, fetch_external_id_map(repo, GameMap)}
    end)
    # 2. Raid variants (Factory day / night). Must precede bosses, which key
    #    their `variant_id` off the ids this step generates.
    |> Ecto.Multi.run(:replace_variants, fn repo, ctx -> replace_variants(repo, maps, ctx) end)
    # 3. Replace every map's sub-entity rows.
    |> Ecto.Multi.run(:replace_bosses, fn repo, ctx -> replace_bosses(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_extracts, fn repo, ctx -> replace_extracts(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_transits, fn repo, ctx -> replace_transits(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_locks, fn repo, ctx -> replace_locks(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_hazards, fn repo, ctx -> replace_hazards(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_spawns, fn repo, ctx -> replace_spawns(repo, maps, ctx) end)
    |> Ecto.Multi.run(:replace_loot_containers, fn repo, ctx ->
      replace_loot_containers(repo, maps, ctx)
    end)
    |> Ecto.Multi.run(:replace_stationary_weapons, fn repo, ctx ->
      replace_stationary_weapons(repo, maps, ctx)
    end)
    |> Ecto.Multi.run(:replace_switches, fn repo, ctx ->
      replace_switches(repo, maps, ctx)
    end)
    |> Ecto.Multi.run(:replace_access_keys, fn repo, ctx ->
      replace_access_keys(repo, maps, ctx)
    end)
    # 4. Drop maps that disappeared from the snapshot (cascades children).
    |> Ecto.Multi.run(:cleanup, fn repo, _ -> cleanup_stale(repo, maps) end)
    # 5. Final counts.
    |> Ecto.Multi.run(:counts, fn repo, _ ->
      {:ok,
       %{
         maps: repo.aggregate(GameMap, :count, :id),
         variants: repo.aggregate(Variant, :count, :id),
         bosses: repo.aggregate(Boss, :count, :id),
         extracts: repo.aggregate(Extract, :count, :id),
         transits: repo.aggregate(Transit, :count, :id),
         locks: repo.aggregate(Lock, :count, :id),
         spawns: repo.aggregate(Spawn, :count, :id),
         loot_containers: repo.aggregate(LootContainer, :count, :id),
         stationary_weapons: repo.aggregate(StationaryWeapon, :count, :id),
         switches: repo.aggregate(Switch, :count, :id),
         access_keys: repo.aggregate(AccessKey, :count, :id)
       }}
    end)
    |> Repo.transaction(timeout: 180_000)
    |> case do
      {:ok, %{counts: counts}} -> {:ok, counts}
      other -> other
    end
  end

  # ── Maps ───────────────────────────────────────────────

  defp upsert_maps(repo, maps, media) do
    now = now_naive()

    rows =
      maps
      |> Enum.uniq_by(& &1["normalizedName"])
      |> Enum.map(fn m ->
        map_media = Map.get(media, m["normalizedName"]) || %{}
        rendering = Map.get(map_media, :rendering) || %{}

        %{
          id: Ecto.UUID.generate(),
          external_id: m["id"],
          name: m["name"],
          normalized_name: m["normalizedName"],
          tarkov_data_id: to_string_or_nil(m["tarkovDataId"]),
          name_id: m["nameId"],
          wiki: m["wiki"],
          svg_path: Map.get(map_media, :svg_path),
          image_variants: Map.get(map_media, :image_variants) || %{},
          description: m["description"],
          enemies: List.wrap(m["enemies"]),
          raid_duration: m["raidDuration"],
          players: m["players"],
          min_player_level: m["minPlayerLevel"],
          max_player_level: m["maxPlayerLevel"],
          access_keys_min_player_level: m["accessKeysMinPlayerLevel"],
          projection: Map.get(rendering, :projection),
          transform: Map.get(rendering, :transform),
          coordinate_rotation: Map.get(rendering, :coordinate_rotation),
          bounds: Map.get(rendering, :bounds),
          svg_bounds: Map.get(rendering, :svg_bounds),
          min_zoom: Map.get(rendering, :min_zoom),
          max_zoom: Map.get(rendering, :max_zoom),
          tile_size: Map.get(rendering, :tile_size),
          tile_path: Map.get(rendering, :tile_path),
          height_range: Map.get(rendering, :height_range),
          layers: Map.get(rendering, :layers) || [],
          labels: Map.get(rendering, :labels) || [],
          image_author: Map.get(rendering, :image_author),
          image_author_link: Map.get(rendering, :image_author_link),
          inserted_at: now,
          updated_at: now
        }
      end)

    bulk_upsert(repo, GameMap, rows,
      conflict_target: :normalized_name,
      replace: [
        :external_id,
        :name,
        :tarkov_data_id,
        :name_id,
        :wiki,
        :svg_path,
        :image_variants,
        :description,
        :enemies,
        :raid_duration,
        :players,
        :min_player_level,
        :max_player_level,
        :access_keys_min_player_level,
        :projection,
        :transform,
        :coordinate_rotation,
        :bounds,
        :svg_bounds,
        :min_zoom,
        :max_zoom,
        :tile_size,
        :tile_path,
        :height_range,
        :layers,
        :labels,
        :image_author,
        :image_author_link,
        :updated_at
      ]
    )
  end

  # ── Variants ───────────────────────────────────────────

  # One row per playable raid, base first. Returns the generated ids keyed by
  # `{map_uuid, variant_slug}` so `replace_bosses/3` can attach each boss entry
  # to the raid it belongs to.
  defp replace_variants(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Variant, :map_id, map_uuids)

    now = now_naive()

    prepared =
      for m <- maps,
          map_id = Map.get(map_ids, m["id"]),
          not is_nil(map_id),
          {payload, spec} <- variant_payloads(m) do
        id = Ecto.UUID.generate()
        {{map_id, payload["normalizedName"]}, variant_row(id, map_id, payload, spec, now)}
      end

    _ = bulk_insert(repo, Variant, Enum.map(prepared, &elem(&1, 1)))

    {:ok, Map.new(prepared, fn {key, row} -> {key, row.id} end)}
  end

  defp variant_row(id, map_id, payload, spec, now) do
    %{
      id: id,
      map_id: map_id,
      external_id: payload["id"],
      normalized_name: payload["normalizedName"],
      name: payload["name"],
      name_id: payload["nameId"],
      label: Map.get(spec, :label),
      base: Map.get(spec, :base, false),
      kind: Map.get(spec, :kind, "base"),
      raid_duration: payload["raidDuration"],
      players: payload["players"],
      min_player_level: payload["minPlayerLevel"],
      max_player_level: payload["maxPlayerLevel"],
      description: payload["description"],
      enemies: List.wrap(payload["enemies"]),
      inserted_at: now,
      updated_at: now
    }
  end

  # ── Bosses ─────────────────────────────────────────────

  # One row per API spawn entry, attached to the raid variant it belongs to.
  #
  # These used to be collapsed to one row per boss, keeping only the first
  # entry's chance / trigger / timer. That produced numbers that were simply
  # wrong: Lighthouse reported "Rogue 80%" when four of its seven zones are
  # 20-50%, and The Lab reported "Raider 60%" for one of five zones while
  # discarding a `Switch` trigger and seven distinct wave times. Cards are
  # regrouped by boss identity on the read side instead.
  defp replace_bosses(repo, maps, ctx) do
    %{map_id_map: map_ids, replace_variants: variant_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Boss, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        # `position` records the API's own ordering, which puts a map's headline
        # boss first. It has to be an explicit column: `inserted_at` is
        # second-precision, so a whole sync shares one timestamp and ordering by
        # it falls through to a random UUID.
        for {payload, _spec} <- variant_payloads(m),
            variant_id = Map.get(variant_ids, {map_id, payload["normalizedName"]}),
            b <- List.wrap(payload["bosses"]),
            not is_nil(b["boss"]) do
          boss_row(map_id, variant_id, b, now)
        end
        |> Enum.with_index()
        |> Enum.map(fn {row, i} -> Map.put(row, :position, i) end)
      end)

    {:ok, bulk_insert(repo, Boss, rows)}
  end

  defp boss_row(map_id, variant_id, b, now) do
    boss = b["boss"]

    %{
      id: Ecto.UUID.generate(),
      map_id: map_id,
      variant_id: variant_id,
      external_id: boss["id"],
      name: boss["name"],
      normalized_name: boss["normalizedName"],
      image_portrait_link: boss["imagePortraitLink"],
      spawn_chance: to_float(b["spawnChance"]),
      spawn_trigger: boss_spawn_trigger(boss["normalizedName"], b["spawnTrigger"]),
      spawn_time: b["spawnTime"],
      spawn_time_random: b["spawnTimeRandom"],
      spawn_locations: normalize_spawn_locations(b["spawnLocations"]),
      escorts: normalize_escorts(b["escorts"]),
      inserted_at: now,
      updated_at: now
    }
  end

  @doc false
  # Public for testing. `spawn_key` is the raw zone key the marker builder
  # joins against `map_spawns.zone_name`; `name` is its translated display
  # form ("ZoneDormitory" -> "Dorms") and is only ever shown to the user.
  def normalize_spawn_locations(locations) when is_list(locations) do
    locations
    |> Enum.map(fn loc ->
      %{
        "spawn_key" => loc["spawnKey"],
        "name" => loc["name"],
        "chance" => to_float(loc["chance"]),
        "positions" => normalize_positions(loc["positions"])
      }
    end)
    # One row per zone: a boss's merged entries repeat zones. Deduped on the
    # *raw* key rather than the display name — two distinct keys can translate
    # to one name, and deduping on the name silently dropped the second zone.
    |> Enum.uniq_by(&(&1["spawn_key"] || &1["name"]))
  end

  def normalize_spawn_locations(_), do: []

  # Keep only positions with usable planar coordinates (x/z drive the map
  # projection; y is the height used for floor filtering).
  defp normalize_positions(positions) when is_list(positions) do
    for p <- positions, is_number(p["x"]) and is_number(p["z"]) do
      %{"x" => to_float(p["x"]), "y" => to_float(p["y"]), "z" => to_float(p["z"])}
    end
  end

  defp normalize_positions(_), do: []

  defp normalize_escorts(escorts) when is_list(escorts) do
    Enum.map(escorts, fn e ->
      boss = e["boss"] || %{}

      amounts =
        (e["amount"] || [])
        |> Enum.map(fn a -> %{"count" => a["count"], "chance" => to_float(a["chance"])} end)

      %{
        "name" => boss["name"],
        "normalized_name" => boss["normalizedName"],
        # Escorts get cards of their own alongside the bosses they serve.
        "image_portrait_link" => boss["imagePortraitLink"],
        "amount" => amounts
      }
    end)
  end

  defp normalize_escorts(_), do: []

  # The Cultist Priest only ever spawns at night, but the API leaves its
  # `spawnTrigger` null on every map it appears on (Customs, Woods, Shoreline,
  # Ground Zero and night Factory). That is a property of the *mob*, not of the
  # map or the raid variant, so it is normalised here rather than being inferred
  # from which payload the entry arrived in.
  #
  # Only fills a missing trigger — a real one is never overwritten. The previous
  # variant merge stamped "Night only" unconditionally, which would have
  # destroyed genuine triggers like `Switch` or `autoId_00000_D2_LEVER`.
  #
  # The window is stated in game hours because "Night only" alone doesn't tell a
  # player whether their raid qualifies.
  @doc false
  def boss_spawn_trigger("cultist-priest", nil), do: "Night only (22:00-07:00)"
  def boss_spawn_trigger(_normalized_name, trigger), do: trigger

  # ── Extracts ───────────────────────────────────────────

  defp replace_extracts(repo, maps, ctx) do
    %{map_id_map: map_ids, item_id_map: items} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Extract, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["extracts"] || [])
        |> Enum.reject(&is_nil(&1["id"]))
        |> Enum.uniq_by(& &1["id"])
        |> Enum.map(fn ex ->
          transfer = ex["transferItem"]
          item_ext_id = get_in(transfer, ["item", "id"])

          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            external_id: ex["id"],
            name: ex["name"],
            faction: ex["faction"],
            transfer_item_id: item_ext_id && Map.get(items, item_ext_id),
            transfer_item_count: transfer && to_float(transfer["count"]),
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(ex))
        end)
      end)

    {:ok, bulk_insert(repo, Extract, rows)}
  end

  # ── Transits ───────────────────────────────────────────

  defp replace_transits(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Transit, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["transits"] || [])
        |> Enum.reject(&is_nil(&1["id"]))
        |> Enum.uniq_by(& &1["id"])
        |> Enum.map(fn tr ->
          dest_ext_id = get_in(tr, ["map", "id"])

          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            external_id: tr["id"],
            description: tr["description"],
            conditions: tr["conditions"],
            # Destination resolves against the same snapshot; nil when the
            # API references a map id that isn't in the maps list (the
            # source of the routine partial `errors`).
            destination_map_id: dest_ext_id && Map.get(map_ids, dest_ext_id),
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(tr))
        end)
      end)

    {:ok, bulk_insert(repo, Transit, rows)}
  end

  # ── Locks ──────────────────────────────────────────────

  # The API lists one lock per physical door. Collapse identical
  # (lockType, needsPower, key) locks into one row + a count.
  defp replace_locks(repo, maps, ctx) do
    %{map_id_map: map_ids, item_id_map: items} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Lock, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["locks"] || [])
        |> Enum.group_by(fn l ->
          {l["lockType"], l["needsPower"], get_in(l, ["key", "id"])}
        end)
        |> Enum.map(fn {{lock_type, needs_power, key_ext_id}, group} ->
          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            lock_type: lock_type,
            needs_power: needs_power,
            key_item_id: key_ext_id && Map.get(items, key_ext_id),
            count: length(group),
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(List.first(group)))
        end)
      end)

    {:ok, bulk_insert(repo, Lock, rows)}
  end

  # ── Hazards ────────────────────────────────────────────

  defp replace_hazards(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Hazard, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["hazards"] || [])
        |> Enum.group_by(fn h -> {h["hazardType"], h["name"]} end)
        |> Enum.map(fn {{hazard_type, name}, group} ->
          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            hazard_type: hazard_type,
            name: name,
            count: length(group),
            positions: normalize_positions(Enum.map(group, & &1["position"])),
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(List.first(group)))
        end)
      end)

    {:ok, bulk_insert(repo, Hazard, rows)}
  end

  # ── Spawns ─────────────────────────────────────────────

  # Every spawn marker on the map is built from these rows — one row per
  # physical spawn point. `map_bosses.spawn_locations[].spawn_key` is only a
  # lookup table: a "boss" row here becomes a boss pin when some boss claims
  # its `zone_name`, and a scav pin when none does (see
  # `EftBuddyWeb.MapsLive.Markers`).
  #
  # `sides` and `categories` are stored raw because that decision is a
  # read-side join against the boss set, and the two `replace_*` passes run
  # independently off different payload keys.
  @stash_containers ~w(buried-barrel-cache ground-cache)

  defp replace_spawns(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Spawn, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["spawns"] || [])
        |> Enum.flat_map(fn s ->
          case classify_spawn(s) do
            nil ->
              []

            type ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  map_id: map_id,
                  spawn_type: type,
                  zone_name: s["zoneName"],
                  sides: List.wrap(s["sides"]),
                  categories: List.wrap(s["categories"]),
                  inserted_at: now,
                  updated_at: now
                }
                |> Map.merge(position_fields(s))
              ]
          end
        end)
      end)

    {:ok, bulk_insert(repo, Spawn, rows)}
  end

  @doc false
  # Order matters, and follows upstream's: the boss category wins outright,
  # then a sniper nest (a scav-sided point with its own category) — which has
  # to be tested *before* the generic scav case or it renders as an ordinary
  # scav — then any scav-side point, then player points are PMC. (A scav-side
  # point that is also player-tagged is a shared scav zone — we surface it as
  # scav.)
  def classify_spawn(%{"categories" => cats} = s) when is_list(cats) do
    sides = List.wrap(s["sides"])

    cond do
      "boss" in cats -> "boss"
      "sniper" in cats and "scav" in sides -> "sniper_scav"
      "scav" in sides -> "scav"
      "player" in cats and ("pmc" in sides or "all" in sides) -> "pmc"
      true -> nil
    end
  end

  def classify_spawn(_), do: nil

  # ── Loot containers (stashes) ──────────────────────────

  # Only the hidden caches become "stash" markers; the API also lists
  # hundreds of mundane loose-loot containers per map that we skip.
  defp replace_loot_containers(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, LootContainer, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["lootContainers"] || [])
        |> Enum.filter(&(get_in(&1, ["lootContainer", "normalizedName"]) in @stash_containers))
        |> Enum.map(fn lc ->
          container = lc["lootContainer"] || %{}

          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            name: container["name"],
            normalized_name: container["normalizedName"],
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(lc))
        end)
      end)

    {:ok, bulk_insert(repo, LootContainer, rows)}
  end

  # ── Stationary weapons ─────────────────────────────────

  defp replace_stationary_weapons(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, StationaryWeapon, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["stationaryWeapons"] || [])
        |> Enum.map(fn sw ->
          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            name: sw["name"],
            normalized_name: sw["normalizedName"],
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(sw))
        end)
      end)

    {:ok, bulk_insert(repo, StationaryWeapon, rows)}
  end

  # ── Switches ───────────────────────────────────────────

  defp replace_switches(repo, maps, ctx) do
    %{map_id_map: map_ids} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, Switch, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["switches"] || [])
        |> Enum.map(fn sw ->
          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            external_id: sw["id"],
            switch_type: sw["switchType"],
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(position_fields(sw))
        end)
      end)

    {:ok, bulk_insert(repo, Switch, rows)}
  end

  # ── Access keys ────────────────────────────────────────
  defp replace_access_keys(repo, maps, ctx) do
    %{map_id_map: map_ids, item_id_map: items} = ctx
    map_uuids = resolve_map_uuids(maps, map_ids)
    delete_in_chunks(repo, AccessKey, :map_id, map_uuids)

    now = now_naive()

    rows =
      for_each_map(maps, map_ids, fn map_id, m ->
        (m["accessKeys"] || [])
        |> Enum.map(& &1["id"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&Map.get(items, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn item_id ->
          %{
            id: Ecto.UUID.generate(),
            map_id: map_id,
            item_id: item_id,
            inserted_at: now,
            updated_at: now
          }
        end)
      end)

    {:ok, bulk_insert(repo, AccessKey, rows)}
  end

  # ── Cleanup ────────────────────────────────────────────

  defp cleanup_stale(repo, maps) do
    valid_map_ids = Enum.map(maps, & &1["id"])
    current = repo.aggregate(GameMap, :count, :id)

    case cleanup_safe?(current, length(valid_map_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale map cleanup: #{reason}. Keeping existing rows."
        )

        {:ok, %{maps: 0}}

      :ok ->
        {count, _} =
          from(m in GameMap, where: m.external_id not in ^valid_map_ids)
          |> repo.delete_all()

        {:ok, %{maps: count}}
    end
  end

  # ── Helpers ────────────────────────────────────────────

  # Run `fun.(map_uuid, raw_map)` for every map whose external id
  # resolves to a local UUID, flattening the per-map row lists into one.
  defp for_each_map(maps, map_ids, fun) do
    Enum.flat_map(maps, fn m ->
      case Map.get(map_ids, m["id"]) do
        nil -> []
        map_id -> fun.(map_id, m)
      end
    end)
  end

  defp resolve_map_uuids(maps, map_ids) do
    maps
    |> Enum.map(&Map.get(map_ids, &1["id"]))
    |> Enum.reject(&is_nil/1)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  # Extract `{pos_x, pos_y, pos_z}` from a sub-entity's `position`
  # object. The API may omit it entirely (nil position) — those rows
  # just carry no coordinates and get no map marker.
  defp position_fields(%{"position" => %{} = pos}) do
    %{pos_x: to_float(pos["x"]), pos_y: to_float(pos["y"]), pos_z: to_float(pos["z"])}
  end

  defp position_fields(_), do: %{pos_x: nil, pos_y: nil, pos_z: nil}

  defp fetch_external_id_map(repo, schema) do
    from(x in schema, select: {x.external_id, x.id})
    |> repo.all()
    |> Map.new()
  end

  defp bulk_upsert(_repo, _schema, [], _opts), do: {:ok, 0}

  defp bulk_upsert(repo, schema, rows, opts) do
    conflict_target = Keyword.fetch!(opts, :conflict_target)
    replace = Keyword.fetch!(opts, :replace)

    total =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          repo.insert_all(schema, chunk,
            on_conflict: {:replace, replace},
            conflict_target: conflict_target
          )

        acc + count
      end)

    {:ok, total}
  end

  defp bulk_insert(_repo, _schema, []), do: 0

  defp bulk_insert(repo, schema, rows) do
    rows
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} = repo.insert_all(schema, chunk)
      acc + count
    end)
  end

  defp delete_in_chunks(_repo, _schema, _field, []), do: :ok

  defp delete_in_chunks(repo, schema, field, ids) do
    ids
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      from(r in schema, where: field(r, ^field) in ^chunk)
      |> repo.delete_all()
    end)
  end

  defp prefix, do: Reporter.colorize_label("MapsSync")
end
