defmodule EftBuddy.Ammo.Sync do
  @moduledoc """
  Syncs ammunition rounds and their ballistics from the tarkov.dev JSON
  API (via `EftBuddy.TarkovApi.ammo/1`) into the `ammo` table.

  Ammo ballistics only change on wipes / patches, so this runs on a slow
  daily cadence: the cold-start `EftBuddy.Sync.Bootstrap` runs it once on
  boot, and thereafter this GenServer re-runs it every 24h. A dev can also
  trigger it on demand from IEx:

      EftBuddy.Ammo.Sync.run()       # synchronous, in the caller
      EftBuddy.Ammo.Sync.sync_now()  # async, in the sync process

  It used to have no schedule at all, which made data correctness a function
  of deploy cadence: a node that stayed up across a wipe served the previous
  wipe's ballistics indefinitely, and `/health/sync` reported `ok` while it
  did, because a feed with no timer cannot be judged on age (see
  `EftBuddy.Sync.Freshness`).

  It must run **after** `EftBuddy.Items.Sync.run_items/0` because every
  round links back to its `items` row (`ammo.item_id`) for the display
  name, icon and availability. Rounds whose item isn't in the snapshot
  yet are still inserted with a null `item_id` and re-linked on the next
  run.

  The sync is idempotent: each run upserts the full snapshot keyed on
  `external_id` (so UUIDs stay stable) and prunes rounds the API dropped,
  subject to the `cleanup_safe?/3` partial-snapshot guard.
  """

  # This module's slot in the daily cycle. The wipe-scale syncs are spaced so
  # they never overlap each other, and so none collides with the wiki chain.
  #
  # The order of the slots preserves `EftBuddy.Sync.Bootstrap`'s FK ordering
  # within a cycle, so a fresh upstream row is normally written before whatever
  # references it. Nothing DEPENDS on that: each of these syncs is idempotent and
  # re-links its FKs on the next run, so the worst case out of order is a null
  # `item_id` for one cycle rather than a broken row.
  use EftBuddy.Sync.Scheduler,
    label: "AmmoSync",
    interval: 12 * 60 * 60 * 1_000,
    stagger: 230 * 60 * 1_000,
    bootstrap: :ran,
    config_key: :ammo

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Ammo.Round
  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  @impl EftBuddy.Sync.Scheduler
  def do_run do
    Reporter.with_run("AmmoSync", fn ->
      case EftBuddy.TarkovApi.ammo() do
        {:ok, raw} ->
          rounds = sanitize(raw)

          case upsert_all(rounds) do
            {:ok, counts} -> {:ok, counts}
            {:error, _, reason, _} -> {:error, reason}
            {:error, reason} -> {:error, reason}
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

  # ── Sanitize ───────────────────────────────────────────

  # Keep only rounds that carry the fields we key on (id + caliber +
  # ammoType). Everything else is coerced at row-build time, so a stray
  # null numeric can never break the `NOT NULL` insert.
  defp sanitize(raw) do
    Enum.filter(raw, fn
      %{"id" => id, "caliber" => caliber, "ammoType" => ammo_type}
      when is_binary(id) and is_binary(caliber) and is_binary(ammo_type) ->
        true

      _ ->
        false
    end)
  end

  # ── Pipeline ───────────────────────────────────────────

  defp upsert_all([]), do: {:ok, %{ammo: 0}}

  defp upsert_all(rounds) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:item_id_map, fn repo, _ ->
      {:ok, fetch_item_id_map(repo)}
    end)
    |> Ecto.Multi.run(:upsert, fn repo, %{item_id_map: item_ids} ->
      upsert_rounds(repo, rounds, item_ids)
    end)
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      cleanup_stale(repo, rounds)
    end)
    |> Ecto.Multi.run(:counts, fn repo, _ ->
      {:ok, %{ammo: repo.aggregate(Round, :count, :id)}}
    end)
    |> Repo.transaction(timeout: 120_000)
    |> case do
      {:ok, %{counts: counts, upsert: upserted}} -> {:ok, Map.put(counts, :upserted, upserted)}
      other -> other
    end
  end

  defp fetch_item_id_map(repo) do
    from(i in Item, select: {i.external_id, i.id})
    |> repo.all()
    |> Map.new()
  end

  defp upsert_rounds(repo, rounds, item_ids) do
    now = now_naive()

    rows =
      Enum.map(rounds, fn r ->
        %{
          id: Ecto.UUID.generate(),
          external_id: r["id"],
          item_id: Map.get(item_ids, r["id"]),
          caliber: r["caliber"],
          ammo_type: r["ammoType"],
          damage: to_int(r["damage"]),
          penetration_power: to_int(r["penetrationPower"]),
          penetration_chance: to_float(r["penetrationChance"]) || 0.0,
          armor_damage: to_int(r["armorDamage"]),
          ricochet_chance: to_float(r["ricochetChance"]) || 0.0,
          accuracy_modifier: to_float(r["accuracyModifier"]) || 0.0,
          recoil_modifier: to_float(r["recoilModifier"]) || 0.0,
          initial_speed: to_float(r["initialSpeed"]) || 0.0,
          projectile_count: to_int(r["projectileCount"], 1),
          light_bleed_modifier: to_float(r["lightBleedModifier"]) || 0.0,
          heavy_bleed_modifier: to_float(r["heavyBleedModifier"]) || 0.0,
          stack_max_size: to_int(r["stackMaxSize"], 1),
          tracer: r["tracer"] == true,
          tracer_color: r["tracerColor"] || "clear",
          inserted_at: now,
          updated_at: now
        }
      end)

    replace = [
      :item_id,
      :caliber,
      :ammo_type,
      :damage,
      :penetration_power,
      :penetration_chance,
      :armor_damage,
      :ricochet_chance,
      :accuracy_modifier,
      :recoil_modifier,
      :initial_speed,
      :projectile_count,
      :light_bleed_modifier,
      :heavy_bleed_modifier,
      :stack_max_size,
      :tracer,
      :tracer_color,
      :updated_at
    ]

    total =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          repo.insert_all(Round, chunk,
            on_conflict: {:replace, replace},
            conflict_target: :external_id
          )

        acc + count
      end)

    {:ok, total}
  end

  # ── Cleanup ────────────────────────────────────────────

  defp cleanup_stale(repo, rounds) do
    valid_ids = Enum.map(rounds, & &1["id"])
    current = repo.aggregate(Round, :count, :id)

    case cleanup_safe?(current, length(valid_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale ammo cleanup: #{reason}. Keeping existing rows."
        )

        {:ok, %{deleted: 0}}

      :ok ->
        {count, _} =
          from(a in Round, where: a.external_id not in ^valid_ids)
          |> repo.delete_all()

        {:ok, %{deleted: count}}
    end
  end

  # ── Helpers ────────────────────────────────────────────

  # Integer coercion for the count/stat columns. The API types these as
  # integers, but a float (or missing value) shouldn't break the insert:
  # truncate floats, and fall back to `default` for anything non-numeric.
  defp to_int(value, default \\ 0)
  defp to_int(value, _default) when is_integer(value), do: value
  defp to_int(value, _default) when is_float(value), do: trunc(value)
  defp to_int(_value, default), do: default
end
