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
  #
  # `db_error?` is true when the page's own read failed (the database is
  # unreachable). That is an error with a Retry, not "still syncing": the Maps
  # page rescued exactly that into an empty list, so a database outage showed the
  # standby spinner forever with no way to retry (audit L18).
  @spec resolve(boolean(), atom() | [binary()], boolean()) :: t()
  def resolve(has_data?, feed, db_error? \\ false)
  def resolve(true, _feed, _db_error?), do: :loaded
  def resolve(false, _feed, true), do: :error

  def resolve(false, feed, false) do
    if any_failed?(feed_labels(feed)), do: :error, else: :loading
  end

  @doc """
  Assign `:load_state` for a page, so templates read `@load_state` instead of
  computing it in a template-local variable, which disables LiveView's change
  tracking for everything below it (audit M17).
  """
  @spec assign_load_state(Phoenix.LiveView.Socket.t(), boolean(), atom() | [binary()], boolean()) ::
          Phoenix.LiveView.Socket.t()
  def assign_load_state(socket, has_data?, feed, db_error? \\ false) do
    Phoenix.Component.assign(socket, :load_state, resolve(has_data?, feed, db_error?))
  end

  @doc """
  When each base sync label last succeeded, as `%{"PricesSync" => DateTime.t()}`.
  A label with mode-suffixed runs reports its most recent success across modes;
  a label that has not succeeded since boot is absent.
  """
  @spec last_ok_at() :: %{binary() => DateTime.t()}
  def last_ok_at do
    Reporter.status()
    |> Enum.flat_map(fn {label, s} ->
      case Map.get(s, :last_ok_at) do
        %DateTime{} = at -> [{base_label(label), at}]
        _ -> []
      end
    end)
    |> Enum.reduce(%{}, fn {base, at}, acc ->
      Map.update(acc, base, at, &Enum.max([&1, at], DateTime))
    end)
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
