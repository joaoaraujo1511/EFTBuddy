defmodule EftBuddyWeb.SyncAware do
  @moduledoc """
  Keeps a browse page in step with the background syncs that feed it.

  An `on_mount` hook in the `:operator` live_session. On a connected mount it
  subscribes to `EftBuddy.Sync.Reporter.sync_topic/0` and assigns `:sync_ok_at`,
  when each feed last succeeded (`EftBuddyWeb.LoadState.last_ok_at/0`). When a
  run finishes:

    * `:sync_ok_at` is refreshed, which moves any "updated N min ago" line
      (`EftBuddyWeb.UI.data_age/1`);
    * if the finished feed is one of this page's and the page is still waiting
      for data (`@load_state != :loaded`), the page is sent `:reload_after_sync`
      and reloads. A page that mounted before its first sync used to sit in
      standby until the visitor reloaded it by hand (audit L18).

  A page that already shows data is not reloaded under the reader; only its age
  line moves. Pages with no standby state are left alone: the bug report form,
  and the map and chapter detail pages, which 404 rather than wait.

  Every page listed here implements `handle_info(:reload_after_sync, socket)`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias EftBuddy.Sync.Reporter
  alias EftBuddyWeb.LoadState

  @view_feeds %{
    EftBuddyWeb.TasksLive.Index => :tasks,
    EftBuddyWeb.ItemsLive.Index => :items,
    EftBuddyWeb.FleaMarketLive.Index => :flea_market,
    EftBuddyWeb.AmmoLive.Index => :ammo,
    EftBuddyWeb.HideoutLive.Index => :hideout,
    EftBuddyWeb.MapsLive.Index => :maps,
    EftBuddyWeb.EventsLive.Index => :events,
    EftBuddyWeb.StorylineLive.Index => :storyline
  }

  @doc "The page key `EftBuddyWeb.LoadState` uses for `view`, or nil."
  @spec feed_for(module()) :: atom() | nil
  def feed_for(view), do: Map.get(@view_feeds, view)

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, :sync_ok_at, LoadState.last_ok_at())

    case feed_for(socket.view) do
      nil ->
        {:cont, socket}

      feed ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(EftBuddy.PubSub, Reporter.sync_topic())

        {:cont, attach_hook(socket, :sync_aware, :handle_info, &on_sync(feed, &1, &2))}
    end
  end

  defp on_sync(feed, {:sync_finished, label, _outcome}, socket) do
    socket = assign(socket, :sync_ok_at, LoadState.last_ok_at())

    if label in LoadState.feed_labels(feed) and Map.get(socket.assigns, :load_state) != :loaded,
      do: send(self(), :reload_after_sync)

    {:halt, socket}
  end

  defp on_sync(_feed, _msg, socket), do: {:cont, socket}
end
