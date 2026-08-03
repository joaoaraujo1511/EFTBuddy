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
    Warmer.warm_all()

    # Asynchronous by design — `warm_all/0` returns before the batch has run, so
    # the numbers below will not have moved yet. The refresh loop picks them up.
    {:noreply, load(socket)}
  end

  defp load(socket) do
    assign(socket, stats: Cache.stats(), entries: Cache.entries(), specs: Warmer.specs())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.row>
      <:col>
        <.card title="Entries" inner_title={state_label(@stats)}>
          {@stats.entries}
        </.card>
      </:col>
      <:col>
        <.card
          title="Hit rate"
          inner_title="since boot"
          inner_hint="Hits over total reads. A low rate means the keys being written are not the keys being read — every page still works, and the cache saves nothing."
        >
          {hit_rate(@stats)}
        </.card>
      </:col>
      <:col>
        <.card title="Table memory" inner_title={"#{@stats.hits} hits / #{@stats.misses} misses"}>
          {bytes(@stats.memory_bytes)}
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
      hint="Which reads get rebuilt ahead of any request, and which syncers finishing trigger the rebuild."
    />
    <div class="card mb-4">
      <div class="card-body p-0">
        <table class="table table-hover mt-0 dash-table">
          <thead>
            <tr>
              <th>Spec</th>
              <th>Rebuilt when these finish</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={spec <- @specs}>
              <td class="tabular-column-name">{spec.label}</td>
              <td>{Enum.join(spec.sources, ", ")}</td>
            </tr>
            <tr :if={@specs == []}>
              <td colspan="2" class="text-center py-3">
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
    """
  end

  defp state_label(%{enabled: false}), do: "DISABLED"
  defp state_label(_), do: "live"

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
