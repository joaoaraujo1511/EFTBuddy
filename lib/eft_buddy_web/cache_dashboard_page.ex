defmodule EftBuddyWeb.CacheDashboardPage do
  @moduledoc """
  A LiveDashboard page for `EftBuddy.Cache`.

  ## Why the cache needs a window

  Caching moves correctness into invisible state. Every other failure in this
  app announces itself — a sync that fails logs, a query that breaks raises, a
  page that cannot render 500s. A cache gets all of them right and still be
  wrong, by serving an answer that stopped being true. There is no exception to
  catch and no line in the log.

  Three numbers here answer the three ways that happens:

    * **Entries** — zero, shortly after a sync, means invalidation is firing and
      warming is not. The table should refill within seconds of a feed finishing.

    * **Hit rate** — a low one means the keys being written are not the keys
      being read. That is the failure mode that looks *exactly* like success:
      every read returns the right answer, every page works, and the cache is
      paying a lookup and a staleness risk to save nothing. It is how a warm
      spec built with the wrong argument shape (`"regular"` where the UI passes
      `:pvp`) would present.

    * **Age** — an entry older than its owning syncer's interval means the
      invalidation signal for that source is not arriving, and the 20-minute TTL
      has quietly become the whole mechanism.

  Reachable only over the SSH tunnel that fronts `EftBuddyWeb.AdminEndpoint`, so
  the operator's key is the authentication.
  """

  use Phoenix.LiveDashboard.PageBuilder

  alias EftBuddy.Cache
  alias EftBuddy.Cache.Warmer

  @impl true
  def menu_link(_session, _capabilities), do: {:ok, "Cache"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  # Called by LiveDashboard's own refresh loop, so the page tracks a live node
  # rather than whatever was true when it was opened.
  def handle_refresh(socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("warm", _params, socket) do
    Warmer.warm_all(:light)

    # Asynchronous by design — `warm_all/1` returns before the batch has run, so
    # the numbers below will not have moved yet. The refresh loop picks them up.
    {:noreply, load(socket)}
  end

  def handle_event("warm_all", _params, socket) do
    Warmer.warm_all(:all)

    {:noreply, load(socket)}
  end

  defp load(socket) do
    coverage = Warmer.coverage()

    assign(socket,
      stats: Cache.stats(),
      entries: Cache.entries(),
      coverage: coverage,
      summary: Warmer.coverage_summary(),
      dataset: EftBuddy.Items.Dataset.stats()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.row>
      <:col>
        <.card
          title="Warm coverage"
          inner_title={coverage_label(@summary)}
          inner_hint="How many registered warm specs are actually live right now. This is the number that catches a cache that has quietly gone cold: entry count, memory and hit rate can all look plausible while most of the registry has expired, because none of them can express 'what should be warm is not'."
        >
          {@summary.live} / {@summary.total}
        </.card>
      </:col>
      <:col>
        <.card
          title="Hit rate"
          inner_title="visitor reads only"
          inner_hint="Hits over total VISITOR reads; the warmer's own reads are counted separately below. A low rate means the keys being written are not the keys being read — every page still works, and the cache saves nothing."
        >
          {hit_rate(@stats)}
        </.card>
      </:col>
      <:col>
        <.card title="Entries" inner_title={entries_label(@stats)}>
          {@stats.entries}
        </.card>
      </:col>
    </.row>

    <.row>
      <:col>
        <.card title="Table memory" inner_title={"#{@stats.hits} hits / #{@stats.misses} misses"}>
          {bytes(@stats.memory_bytes)}
        </.card>
      </:col>
      <:col>
        <.card
          title="Warmer reads"
          inner_title={"#{@stats.warm_writes} entries written"}
          inner_hint="Reads the warmer made, not visitors. This reads INVERSELY to the hit rate above: with the liveness probe working, warm hits should sit near zero, because the warmer should almost never be reading something it already has. A high warm hit rate means the probe is failing to skip."
        >
          {@stats.warm_hits} / {@stats.warm_hits + @stats.warm_misses}
        </.card>
      </:col>
      <:col>
        <.card
          title="Expiry"
          inner_title={"repair every #{duration(Warmer.repair_interval_ms())}"}
          inner_hint="The default TTL, and the interval at which the warmer re-probes and rebuilds anything that expired. The repair interval is DERIVED from the TTL so the two cannot drift — a warmer ticking on one number while the cache expires on another is what left most of the registry cold."
        >
          {duration(Cache.default_ttl_ms())}
        </.card>
      </:col>
    </.row>

    <.row>
      <:col>
        <.card
          title="Item dataset"
          inner_title={dataset_state(@dataset)}
          inner_hint="The in-memory item catalogue behind Items and Flea Market. When it is not ready, those reads fall back to SQL — slower, never wrong."
        >
          {@dataset.items}
        </.card>
      </:col>
      <:col>
        <.card title="Price rows" inner_title="across both game modes">
          {@dataset.price_rows}
        </.card>
      </:col>
      <:col>
        <.card title="Dataset memory" inner_title={"catalogue age #{dataset_age(@dataset)}"}>
          {bytes(@dataset.memory_bytes)}
        </.card>
      </:col>
    </.row>

    <.card_title
      title="Entries"
      hint="Cached values are deliberately not shown: they are the point of the table and can be megabytes each, so rendering them would make observing the cache cost more than using it."
    />
    <div class="card mb-4">
      <div class="card-body p-0">
        <table class="table table-hover mt-0 dash-table">
          <thead>
            <tr>
              <th>Key</th>
              <th>Invalidated by</th>
              <th class="text-right">Age</th>
              <th class="text-right">TTL left</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="tabular-column-name">{inspect(entry.key)}</td>
              <td>{Enum.join(entry.sources, ", ")}</td>
              <td class="text-right">{duration(entry.age_ms)}</td>
              <td class="text-right">{duration(entry.expires_in_ms)}</td>
            </tr>
            <tr :if={@entries == []}>
              <td colspan="4" class="text-center py-3">
                Empty. Expected right after a sync, and for a few seconds after that
                while the warmer refills it — persistent emptiness means warming is
                not running.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <.card_title
      title="Warm registry"
      hint="Which reads get rebuilt ahead of any request, which syncers finishing trigger the rebuild, and whether each one is live right now. A cold row means the next visitor to that page pays the full read."
    />
    <div class="card mb-4">
      <div class="card-body p-0">
        <table class="table table-hover mt-0 dash-table">
          <thead>
            <tr>
              <th>Spec</th>
              <th>Kind</th>
              <th>Rebuilt when these finish</th>
              <th class="text-right">Live</th>
              <th class="text-right">Last warm</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @coverage}>
              <td class="tabular-column-name">{row.label}</td>
              <td>{kind_label(row)}</td>
              <td>{Enum.join(row.sources, ", ")}</td>
              <td class="text-right">{live_label(row)}</td>
              <td class="text-right">{last_warm_label(row)}</td>
            </tr>
            <tr :if={@coverage == []}>
              <td colspan="5" class="text-center py-3">
                No warm specs registered — every entry is built by whichever visitor
                happens to arrive first after a sync.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <button class="btn btn-primary" phx-click="warm">
      Warm now
    </button>
    <button class="btn btn-secondary ml-2" phx-click="warm_all">
      Warm now, including bulk sets
    </button>
    """
  end

  defp coverage_label(%{cold: []}), do: "all live"
  defp coverage_label(%{cold: cold}) when length(cold) <= 3, do: "cold: " <> Enum.join(cold, ", ")
  defp coverage_label(%{cold: cold}), do: "#{length(cold)} cold, incl. #{hd(cold)}"

  defp entries_label(%{enabled: false}), do: "DISABLED"

  defp entries_label(stats),
    do: "#{stats.warm_entries} warm / #{stats.read_entries} read — ceiling #{stats.max_entries}"

  defp kind_label(%{kind: kind, cost: :heavy}), do: "#{kind} (heavy)"
  defp kind_label(%{kind: kind, periodic: false}), do: "#{kind}, not ticked"
  defp kind_label(%{kind: kind}), do: to_string(kind)

  # `:external` specs write outside this cache, so there is nothing to probe.
  # Rendering them as 0/0 would read as cold forever.
  defp live_label(%{state: :unprobed}), do: "n/a"
  defp live_label(%{live: live, expected: expected}), do: "#{live} / #{expected}"

  defp last_warm_label(%{last_warm_at: nil}), do: "never"

  defp last_warm_label(row) do
    ago = DateTime.diff(DateTime.utc_now(), row.last_warm_at, :millisecond)

    "#{duration(ago)} ago · #{row.last_outcome}"
  end

  defp dataset_state(%{enabled: false}), do: "OFF — serving from SQL"
  defp dataset_state(%{building: true}), do: "rebuilding — SQL meanwhile"
  defp dataset_state(%{items: 0}), do: "not built — serving from SQL"
  defp dataset_state(_), do: "live"

  defp dataset_age(%{catalog_age_ms: nil}), do: "never built"
  defp dataset_age(%{catalog_age_ms: ms}), do: duration(ms)

  # nil, not 0%, when nothing has been read yet. "No data" and "every read
  # missed" are opposite diagnoses and must not render identically.
  defp hit_rate(%{hit_rate: nil}), do: "—"
  defp hit_rate(%{hit_rate: rate}), do: "#{round(rate * 100)}%"

  defp bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp bytes(b) when b >= 1_024, do: "#{Float.round(b / 1_024, 1)} KB"
  defp bytes(b), do: "#{b} B"

  # Negative values are possible and meaningful: an entry past its TTL that no
  # read has touched yet is still physically in the table, and hiding that would
  # misrepresent what is actually stored.
  defp duration(ms) when ms < 0, do: "expired"
  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"
  defp duration(ms), do: "#{div(ms, 60_000)} min"
end
