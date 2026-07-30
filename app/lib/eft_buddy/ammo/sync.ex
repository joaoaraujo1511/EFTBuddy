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

  use GenServer

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Ammo.Round
  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  @lock_id {__MODULE__, :running}

  # ── Schedule ───────────────────────────────────────────

  @default_interval 24 * 60 * 60 * 1_000

  # This module's slot in the daily cycle. The five wipe-scale syncs are spaced
  # so they never overlap each other, and so none collides with the wiki chain,
  # which occupies +0 / +1 min / +8 min from the same reference point.
  #
  # The order of the slots preserves `EftBuddy.Sync.Bootstrap`'s FK ordering
  # within a cycle (maps +20 → hideout +30 → ammo +40 → armor +50 → tasks +60),
  # so a fresh upstream row is normally written before whatever references it.
  # Nothing DEPENDS on that: each of these syncs is idempotent and re-links its
  # FKs on the next run, so the worst case out of order is a null `item_id` for
  # one cycle rather than a broken row.
  @stagger 40 * 60 * 1_000

  # Delay to the first SCHEDULED run, measured from `Sync.Bootstrap` casting
  # `:bootstrap_complete`.
  #
  # A FULL INTERVAL, not zero — and this is the one place this module differs
  # from the wiki scrapers whose shape it otherwise copies. Bootstrap *releases*
  # `Chapters.Sync` (which has never run at that point), so an offset of 0 there
  # means "start now". Bootstrap *runs* this module itself, synchronously, as
  # part of the cold-start sequence — so by the time the cast arrives this sync
  # has already happened, and arming at 0 would immediately re-sync the whole
  # snapshot for nothing.
  @bootstrap_offset @default_interval + @stagger

  # Fallback for when the bootstrap signal never arrives: Bootstrap crashed
  # before notifying, or exited early. In that case this sync has NOT run and
  # the table may be empty, so the fallback is short rather than a full day.
  @fallback_delay 15 * 60 * 1_000 + @stagger

  @doc false
  # Public so `EftBuddy.Sync.Freshness` can assert its staleness budget covers
  # this cadence rather than trusting a comment to keep the two in step.
  def interval_ms, do: @default_interval

  @doc false
  # Cluster-wide singleton, same pattern as the other syncers: only one node
  # registers the GenServer and the rest `:ignore` their start_link.
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.info("[#{prefix()}] Another node already runs the ammo sync; staying idle here.")
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
        Logger.info("[#{prefix()}] skipped: another ammo sync is already running")
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
  Run a full sync of ammo. Synchronous: blocks until done.

  Returns `{:ok, counts}` on success or `{:error, reason}`. Returns
  `{:error, :already_running}` if another ammo sync is in progress on any
  node in the cluster.
  """
  def run do
    nodes = [node() | Node.list()]

    case :global.set_lock(@lock_id, nodes, 0) do
      true ->
        try do
          do_run()
        after
          :global.del_lock(@lock_id, nodes)
        end

      false ->
        Logger.warning("[#{prefix()}] Skipped: another sync is already running.")
        {:error, :already_running}
    end
  end

  defp do_run do
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

  defp prefix, do: Reporter.colorize_label("AmmoSync")
end
