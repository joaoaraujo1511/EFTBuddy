defmodule EftBuddyWeb.SyncDashboardPage do
  @moduledoc """
  A LiveDashboard page for the background feeds.

  ## Why the feeds need a window

  This app has no user-authored content, so every page it serves is a rendering
  of what the feeds last wrote. When one stops, nothing breaks: the pages keep
  rendering perfectly and present stale or missing game data as fact. A stopped
  feed also emits no events, so its absence cannot be noticed by anything
  event-driven — it has to be *asked about*, which is what `/health/sync` does
  and what this page shows in full.

  ## The column that is not on `/health/sync`'s critical path

  **Next run** is the one worth explaining, because its absence hid a real bug
  for weeks.

  Everything else here is retrospective — what ran, when, how it went — and none
  of it can describe a feed that has not run yet. Three Fandom scrapes were once
  armed from a stagger meant to place them within their recurring cycle; a
  re-cadence moved one from 1 minute to 180, and since the feed had not run at
  boot, that stagger *was* its delay to a first run. A fresh database served an
  empty events page for three hours and a restart inside that window started the
  wait over. Nothing errored. `EftBuddy.Sync.Freshness` was right to stay quiet:
  it asks "should this have run by now?" against a staleness budget, and three
  hours is well inside twelve.

  A row reading **never · next in 2h58m** says it immediately, which is the whole
  argument for the column.

  The **boot** mode beside each feed's upstream is on the same thread. `:ran` means
  the cold start runs it; `:released` and `:chained` mean it waits for a cast, and
  a feed in either of those reading *never* is the shape of the bug above. Every
  feed is `:ran` today — the column exists so that stops being invisible if one
  ever is not.

  ## What the two tables are for

  The **families** table is what `/health/sync` judges: budgets, ages and the
  verdict derived from them. The **feeds** table is the registry — every feed
  that *should* exist, whether or not it has ever reported. A feed present in the
  second and absent from the first has never run, and that gap is the thing to
  look for.

  Reachable only over the SSH tunnel that fronts `EftBuddyWeb.AdminEndpoint`, so
  the operator's key is the authentication.
  """

  use Phoenix.LiveDashboard.PageBuilder

  alias EftBuddy.Sync.{Freshness, Registry, Reporter}

  @impl true
  def menu_link(_session, _capabilities), do: {:ok, "Syncs"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  # Called by LiveDashboard's own refresh loop, so the page tracks a live node
  # rather than whatever was true when it was opened.
  def handle_refresh(socket), do: {:noreply, load(socket)}

  defp load(socket) do
    freshness = Freshness.evaluate()
    status = Reporter.status()
    schedule = Reporter.schedule()

    assign(socket,
      freshness: freshness,
      families: Enum.sort_by(freshness.syncs, fn {prefix, _} -> prefix end),
      feeds: feed_rows(status, schedule),
      never_run: Enum.count(Registry.children(), &(not reported?(status, &1.label())))
    )
  end

  # One row per registered feed, so a feed that has never reported still appears.
  # Built from the registry rather than from the status table for exactly that
  # reason: a table of what has run cannot show what has not.
  defp feed_rows(status, schedule) do
    Registry.all()
    |> Enum.map(fn feed ->
      label = feed.mod.label()

      %{
        label: label,
        upstream: feed.upstream,
        bootstrap: feed.bootstrap,
        interval_ms: feed.mod.effective_interval_ms(),
        stagger_ms: feed.mod.stagger_ms(),
        run: Map.get(status, label),
        next: Map.get(schedule, label)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp reported?(status, label) do
    Enum.any?(status, fn {recorded, _} ->
      recorded == label or String.starts_with?(recorded, label <> ":")
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.row>
      <:col>
        <.card
          title="Readiness"
          inner_title={"uptime #{duration_s(@freshness.uptime_seconds)}"}
          inner_hint="What GET /health/sync answers. `degraded` returns 503, which drains this instance from rotation — so it goes red only for faults, never for a feed that is merely mid-cycle."
        >
          {@freshness.status}
        </.card>
      </:col>
      <:col>
        <.card
          title="Never run"
          inner_title={"of #{length(@feeds)} registered feeds"}
          inner_hint="Feeds with no recorded run on this node. Non-zero shortly after a boot is normal — the cold start is still working through them. Non-zero an hour in means a feed is waiting on a timer instead of having run, and the Next run column says how long that wait is."
        >
          {@never_run}
        </.card>
      </:col>
      <:col>
        <.card
          title="Refused prunes"
          inner_title="cleanup guard trips"
          inner_hint="A run that declined to delete rows because its snapshot looked partial. It reports success — it did complete — but this instance is knowingly serving data it distrusted, which `outcome` alone cannot express."
        >
          {Enum.sum(for {_p, f} <- @families, do: f.refusals)}
        </.card>
      </:col>
    </.row>

    <.card_title
      title="Families"
      hint="What /health/sync judges. A family is aged from its last SUCCESSFUL run, not its last run — a feed that ticks on schedule and writes nothing every time would otherwise look permanently current."
    />
    <div class="card mb-4">
      <div class="card-body p-0">
        <table class="table table-hover mt-0 dash-table">
          <thead>
            <tr>
              <th>Family</th>
              <th>State</th>
              <th class="text-right">Last success</th>
              <th class="text-right">Budget</th>
              <th class="text-right">Next run</th>
              <th>Labels</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{prefix, f} <- @families}>
              <td class="tabular-column-name">{prefix}</td>
              <td>{f.state}</td>
              <td class="text-right">{age_label(f.age_seconds)}</td>
              <td class="text-right">{duration_s(f.budget_seconds)}</td>
              <td class="text-right">{next_label(f.next_run_seconds)}</td>
              <td>{labels_label(f.labels)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <.card_title
      title="Feeds"
      hint="The registry: every feed that should exist, whether or not it has ever reported. A feed listed here with no row in the table above has never run on this node."
    />
    <div class="card mb-4">
      <div class="card-body p-0">
        <table class="table table-hover mt-0 dash-table">
          <thead>
            <tr>
              <th>Feed</th>
              <th>Upstream · boot</th>
              <th class="text-right">Every</th>
              <th class="text-right">Stagger</th>
              <th class="text-right">Last run</th>
              <th class="text-right">Next run</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={feed <- @feeds}>
              <td class="tabular-column-name">{feed.label}</td>
              <td>{feed.upstream} · {feed.bootstrap}</td>
              <td class="text-right">{duration_ms(feed.interval_ms)}</td>
              <td class="text-right">{duration_ms(feed.stagger_ms)}</td>
              <td class="text-right">{last_run_label(feed.run)}</td>
              <td class="text-right">{next_feed_label(feed.next)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # `nil`, not "0s ago". "Has never succeeded" and "succeeded this instant" are
  # opposite diagnoses and must not render identically — the same reason
  # `Freshness` reports `age_seconds: nil` rather than zero.
  defp age_label(nil), do: "never"
  defp age_label(seconds), do: "#{duration_s(seconds)} ago"

  defp next_label(nil), do: "—"
  defp next_label(seconds), do: relative(seconds)

  defp labels_label([]), do: "—"
  defp labels_label(labels), do: Enum.join(labels, ", ")

  defp last_run_label(nil), do: "never"

  defp last_run_label(run) do
    ago = DateTime.diff(DateTime.utc_now(), run.at)

    "#{duration_s(ago)} ago · #{run.outcome}"
  end

  # A feed with no schedule row has not armed a timer at all, which for a
  # supervised feed means its `init/1` has not run — a different and worse
  # condition than "armed, waiting", so it does not render as a dash.
  defp next_feed_label(nil), do: "not armed"

  defp next_feed_label(%{next_run_at: at}) do
    at |> DateTime.diff(DateTime.utc_now()) |> relative()
  end

  # Negative is meaningful, not a rounding artefact: the planned moment has
  # passed and no run has been recorded since. Briefly that is a run in flight;
  # persistently it is a feed that armed a timer and never fired.
  defp relative(seconds) when seconds < 0, do: "overdue #{duration_s(-seconds)}"
  defp relative(seconds), do: "in #{duration_s(seconds)}"

  defp duration_ms(ms), do: duration_s(div(ms, 1_000))

  defp duration_s(s) when s < 60, do: "#{s}s"
  defp duration_s(s) when s < 3_600, do: "#{div(s, 60)}m"
  defp duration_s(s) when s < 86_400, do: "#{div(s, 3_600)}h #{rem(div(s, 60), 60)}m"
  defp duration_s(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3_600), 24)}h"
end
