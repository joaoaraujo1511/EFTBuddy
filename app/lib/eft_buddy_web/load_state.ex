defmodule EftBuddyWeb.LoadState do
  @moduledoc """
  Shared "is this page's data ready?" resolution for the browse LiveViews.

  Every browse page defers its heavy queries to the connected mount (so the
  disconnected static render doesn't run them a second time), and the data
  itself is populated asynchronously by the background sync. Until the sync
  has written rows to the DB, a page has nothing to show. This module
  collapses that situation into a single tri-state the templates key off,
  so every page's not-loaded screen is identical:

    * `:loaded`  - the page has data; render the normal UI.
    * `:error`   - the page has no data **and** the sync that feeds it last
                   failed, so the rows likely won't arrive on their own.
                   The `standby` panel shows a fault marker + a Retry action.
    * `:loading` - the page has no data and no failure is recorded; the sync
                   is presumably still running. The `standby` panel shows the
                   spinning "standby" marker.

  The `:error` signal is read from `EftBuddy.Sync.Reporter.status/0` - an
  ETS-backed, per-label record of each sync's last-run outcome - so no new
  plumbing (PubSub, GenServer, …) is needed. `feed_labels/1` maps a page key
  to the sync label(s) whose failure means that page's data won't show.

  Matching is done on the **base** label (the part before any `:mode`
  suffix), because a couple of syncers run per game mode and tag themselves
  `"TasksSync:pve"` / `"PricesSync:regular"` etc.
  """

  alias EftBuddy.Sync.Reporter

  @type t :: :loading | :loaded | :error

  @page_feeds %{
    tasks: ["TasksSync"],
    items: ["ItemsSync"],
    flea_market: ["ItemsSync", "PricesSync"],
    ammo: ["AmmoSync", "ArmorSync"],
    hideout: ["HideoutSync"],
    maps: ["MapsSync"],
    events: ["EventsSync"],
    storyline: ["ChaptersSync"]
  }

  @doc """
  Resolve the tri-state for a page.

  `has_data?` is the page's own "do I have rows to render?" boolean.
  `feed` is either a page key (atom, e.g. `:tasks`) or an explicit list of
  base sync labels.
  """
  @spec resolve(boolean(), atom() | [binary()]) :: t()
  def resolve(true, _feed), do: :loaded

  def resolve(false, feed) do
    if any_failed?(feed_labels(feed)), do: :error, else: :loading
  end

  @doc "Base sync labels that feed a page key (or the list passed through)."
  @spec feed_labels(atom() | [binary()]) :: [binary()]
  def feed_labels(feed) when is_list(feed), do: feed
  def feed_labels(feed) when is_atom(feed), do: Map.get(@page_feeds, feed, [])

  # True if any feeding sync's most recent run failed. Compares on the base
  # label so mode-suffixed runs (`"TasksSync:pve"`) match their page.
  defp any_failed?([]), do: false

  defp any_failed?(labels) do
    wanted = MapSet.new(labels)

    Reporter.status()
    |> Enum.any?(fn {label, outcome} ->
      outcome.outcome == :error and MapSet.member?(wanted, base_label(label))
    end)
  end

  defp base_label(label) when is_binary(label) do
    label |> String.split(":", parts: 2) |> hd()
  end

  defp base_label(_), do: ""
end
