defmodule EftBuddyWeb.GoonsLive.Index do
  @moduledoc """
  "Goons" - a dedicated tracker for the roaming Goon squad (Knight, Big Pipe
  and Birdeye).

  Unlike the other trackers, the Goons can only ever be on ONE map at a time,
  so the whole page is built around a single "current location" marker: a hero
  panel showing where they are right now, and a map picker that moves that
  marker (selecting a map is exclusive - picking a new one clears the old).

  This is currently a FRONTEND TEMPLATE only: the current location, timings and
  report counts are illustrative local state so the layout and the
  single-location interaction can be reviewed. Wiring it to a real community
  sighting feed is the follow-up.
  """
  use EftBuddyWeb, :live_view

  # The maps the Goons are known to patrol. Pinned here so the picker and the
  # hero panel agree on the candidate set.
  @maps ["Customs", "Woods", "Shoreline", "Lighthouse"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Goons")
     |> assign(:active, :goons)
     # Sample starting state: last reported on Customs a few minutes ago.
     |> assign(:current_map, "Customs")
     |> assign(:reported, "8 min ago")
     |> assign(:confidence, "High")
     |> assign(:reports, 12)}
  end

  # Move the single sighting marker to a map. Because the squad can only be in
  # one place, this is exclusive - setting a new map implicitly clears the old
  # one. (Template behaviour: a real version would post a community report.)
  @impl true
  def handle_event("set_location", %{"map" => map}, socket) when map in @maps do
    {:noreply,
     socket
     |> assign(:current_map, map)
     |> assign(:reported, "Just now (you)")
     |> assign(:confidence, "High")
     |> assign(:reports, 1)}
  end

  def handle_event("set_location", _params, socket), do: {:noreply, socket}

  # Operator hasn't seen them anywhere / clearing a stale marker.
  def handle_event("clear_location", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_map, nil)
     |> assign(:reported, nil)
     |> assign(:confidence, nil)
     |> assign(:reports, 0)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def maps, do: @maps

  @doc false
  def squad do
    [
      %{
        name: "Knight",
        role: "Squad leader",
        note: "Heavy armour, aggressive push.",
        icon: "hero-user"
      },
      %{
        name: "Big Pipe",
        role: "Grenadier",
        note: "M32A1 - relentless under-barrel spam.",
        icon: "hero-fire"
      },
      %{
        name: "Birdeye",
        role: "Marksman",
        note: "Long-range support, picks stragglers.",
        icon: "hero-viewfinder-circle"
      }
    ]
  end
end
