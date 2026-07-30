defmodule EftBuddy.Armor.Sync do
  @moduledoc """
  Syncs ballistic armor plates and their stats from the tarkov.dev JSON
  API (via `EftBuddy.TarkovApi.plates/1`) into the `armor_plates` table.

  Like `EftBuddy.Ammo.Sync` / `EftBuddy.Maps.Sync`, this is **not** a
  `GenServer` and is **not** scheduled: plate stats only change on wipes /
  patches, so `EftBuddy.Sync.Bootstrap` runs it once on boot and a dev can
  re-run it on demand:

      EftBuddy.Armor.Sync.run()

  It must run **after** `EftBuddy.Items.Sync.run_items/0` because every
  plate links back to its `items` row (`armor_plates.item_id`) for the
  display name, icon and price. Plates whose item isn't in the snapshot
  yet are inserted with a null `item_id` and re-linked next run.

  Idempotent: each run upserts the full snapshot keyed on `external_id`
  and prunes plates the API dropped (subject to the `cleanup_safe?/3`
  partial-snapshot guard).
  """

  use GenServer

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Armor.Plate
  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  @lock_id {__MODULE__, :running}

  # ── Schedule ───────────────────────────────────────────
  #
  # See `EftBuddy.Ammo.Sync`'s schedule section for the full reasoning; the two
  # modules are deliberately identical here apart from the slot.

  @default_interval 24 * 60 * 60 * 1_000

  # Slot in the daily cycle: maps +20 → hideout +30 → ammo +40 → armor +50 →
  # tasks +60, which keeps Bootstrap's FK ordering inside a cycle and avoids the
  # wiki chain's +0 / +1 min / +8 min.
  @stagger 50 * 60 * 1_000

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
        Logger.info("[#{prefix()}] Another node already runs the armor sync; staying idle here.")
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
        Logger.info("[#{prefix()}] skipped: another armor sync is already running")
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
  Run a full sync of armor plates. Synchronous: blocks until done.
  Returns `{:ok, counts}` / `{:error, reason}`, or
  `{:error, :already_running}` if another armor sync holds the lock.
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
    Reporter.with_run("ArmorSync", fn ->
      case EftBuddy.TarkovApi.plates() do
        {:ok, raw} ->
          plates = sanitize(raw)

          case upsert_all(plates) do
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

  # Keep only plates carrying the fields we key on (id + class + material
  # + armorType). The numeric fields are coerced at row-build time, so a
  # stray null never breaks the `NOT NULL` insert.
  defp sanitize(raw) do
    Enum.filter(raw, fn
      %{"id" => id, "class" => class, "material" => material, "armorType" => armor_type}
      when is_binary(id) and is_integer(class) and is_binary(material) and is_binary(armor_type) ->
        true

      _ ->
        false
    end)
  end

  # ── Pipeline ───────────────────────────────────────────

  defp upsert_all([]), do: {:ok, %{armor_plates: 0}}

  defp upsert_all(plates) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:item_id_map, fn repo, _ -> {:ok, fetch_item_id_map(repo)} end)
    |> Ecto.Multi.run(:upsert, fn repo, %{item_id_map: item_ids} ->
      upsert_plates(repo, plates, item_ids)
    end)
    |> Ecto.Multi.run(:cleanup, fn repo, _ -> cleanup_stale(repo, plates) end)
    |> Ecto.Multi.run(:counts, fn repo, _ ->
      {:ok, %{armor_plates: repo.aggregate(Plate, :count, :id)}}
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

  defp upsert_plates(repo, plates, item_ids) do
    now = now_naive()

    rows =
      Enum.map(plates, fn p ->
        %{
          id: Ecto.UUID.generate(),
          external_id: p["id"],
          item_id: Map.get(item_ids, p["id"]),
          class: to_int(p["class"]),
          durability: to_int(p["durability"]),
          material: p["material"],
          armor_type: p["armorType"],
          blunt_throughput: to_float(p["bluntThroughput"]) || 0.0,
          speed_penalty: to_float(p["speedPenalty"]) || 0.0,
          turn_penalty: to_float(p["turnPenalty"]) || 0.0,
          ergo_penalty: to_float(p["ergoPenalty"]) || 0.0,
          repair_cost: to_int(p["repairCost"]),
          inserted_at: now,
          updated_at: now
        }
      end)

    replace = [
      :item_id,
      :class,
      :durability,
      :material,
      :armor_type,
      :blunt_throughput,
      :speed_penalty,
      :turn_penalty,
      :ergo_penalty,
      :repair_cost,
      :updated_at
    ]

    total =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          repo.insert_all(Plate, chunk,
            on_conflict: {:replace, replace},
            conflict_target: :external_id
          )

        acc + count
      end)

    {:ok, total}
  end

  # ── Cleanup ────────────────────────────────────────────

  defp cleanup_stale(repo, plates) do
    valid_ids = Enum.map(plates, & &1["id"])
    current = repo.aggregate(Plate, :count, :id)

    case cleanup_safe?(current, length(valid_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale plate cleanup: #{reason}. Keeping existing rows."
        )

        {:ok, %{deleted: 0}}

      :ok ->
        {count, _} =
          from(p in Plate, where: p.external_id not in ^valid_ids)
          |> repo.delete_all()

        {:ok, %{deleted: count}}
    end
  end

  # ── Helpers ────────────────────────────────────────────

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(_value), do: 0

  defp prefix, do: Reporter.colorize_label("ArmorSync")
end
