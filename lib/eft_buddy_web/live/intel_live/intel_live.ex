defmodule EftBuddyWeb.IntelLive.Index do
  @moduledoc """
  "Intel" - the operator's long-haul progression board.

  A single hub for the marquee, wipe-spanning pursuits players grind toward:

    * **Achievements** - the in-game achievement checklist.
    * **Kappa Collector** - the items + quests gating the Kappa container.
    * **Lightkeeper** - the quest chain that unlocks the Lighthouse trader.

  (The Goon squad tracker lives on its own dedicated tab - see
  `EftBuddyWeb.GoonsLive` - since the Goons can only be on one map at a time
  and that page wants a different shape.)

  This is currently a FRONTEND TEMPLATE only: every figure below is
  illustrative sample data wired into the UI so the layout, sub-navigation
  and per-section components can be reviewed. Hooking these up to real
  progress (the localStorage blob, like Tasks/Items) is the follow-up.
  """
  use EftBuddyWeb, :live_view

  @sections ~w(achievements kappa lightkeeper)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Intel")
     |> assign(:active, :intel)
     |> assign(:section, :achievements)}
  end

  # Sub-tab switch (Achievements / Kappa / Lightkeeper). Client driven via the
  # shared `<.tabs>` strip; defaults to Achievements for anything unexpected so
  # a stray value can never blank the page.
  @impl true
  def handle_event("set_section", %{"filter" => value}, socket) do
    {:noreply, assign(socket, :section, parse_section(value))}
  end

  # Operator/HUD pings and the client-restore blob aren't consumed here yet.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp parse_section(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @sections, do: atom, else: :achievements
  rescue
    ArgumentError -> :achievements
  end

  # ── Sample data (template placeholders) ────────────────

  @doc false
  # Headline progress numbers shown in the summary strip up top.
  def summary_cards do
    [
      %{label: "Achievements", value: "18 / 76", icon: "hero-trophy"},
      %{label: "Kappa Items", value: "23 / 64", icon: "hero-cube"},
      %{label: "Lightkeeper", value: "9 / 26", icon: "hero-key"}
    ]
  end

  @doc false
  def achievements do
    [
      %{
        name: "Welcome to Tarkov",
        desc: "Reach your first successful extraction.",
        rarity: "Common",
        done: true,
        progress: nil
      },
      %{
        name: "The Kappa Path",
        desc: "Obtain the Kappa secure container.",
        rarity: "Legendary",
        done: false,
        progress: "23 / 64"
      },
      %{
        name: "Hundred",
        desc: "Reach PMC level 100.",
        rarity: "Rare",
        done: false,
        progress: "42 / 100"
      },
      %{
        name: "Mastersmith",
        desc: "Build every hideout module to maximum level.",
        rarity: "Rare",
        done: false,
        progress: "11 / 38"
      },
      %{
        name: "Survivalist",
        desc: "Survive 50 raids in a row without dying.",
        rarity: "Hidden",
        done: false,
        progress: "7 / 50"
      },
      %{
        name: "Friend Among Strangers",
        desc: "Reach maximum standing with every trader.",
        rarity: "Epic",
        done: false,
        progress: "2 / 8"
      }
    ]
  end

  @doc false
  # A handful of the Collector quest items gating Kappa, with a sample
  # found state. The real version reads the localStorage progress blob.
  def kappa_items do
    [
      %{name: "Golden Zibbo lighter", found: true},
      %{name: "Antique teapot", found: true},
      %{name: "Roler Submariner gold wrist watch", found: false},
      %{name: "Chain with Prokill medallion", found: false},
      %{name: "Carbon case", found: true},
      %{name: "Bronze lion figurine", found: false},
      %{name: "Cat figurine", found: false},
      %{name: "Battered antique book", found: true},
      %{name: "Cult amulet", found: false},
      %{name: "Veritas guitar pick", found: false},
      %{name: "Soap", found: true},
      %{name: "Old firesteel", found: false}
    ]
  end

  @doc false
  def lightkeeper_chain do
    [
      %{name: "Network Provider - Part 1", trader: "Lightkeeper", status: :done},
      %{name: "Network Provider - Part 2", trader: "Lightkeeper", status: :done},
      %{name: "Knock-Knock", trader: "Lightkeeper", status: :active},
      %{name: "Make Amends - Buyout", trader: "Skier", status: :active},
      %{name: "Getting Acquainted", trader: "Lightkeeper", status: :locked},
      %{name: "Make Ultimatum", trader: "Lightkeeper", status: :locked},
      %{name: "Provide Cover", trader: "Lightkeeper", status: :locked}
    ]
  end

  # ── Template helpers ───────────────────────────────────

  @doc false
  def rarity_tone("Legendary"), do: :amber
  def rarity_tone("Epic"), do: :purple
  def rarity_tone("Rare"), do: :signal
  def rarity_tone("Hidden"), do: :warn
  def rarity_tone(_), do: :neutral

  @doc false
  def lk_status_label(:done), do: "Completed"
  def lk_status_label(:active), do: "Available"
  def lk_status_label(:locked), do: "Locked"

  def lk_status_classes(:done), do: "bg-signal/10 text-signal border-signal/30"
  def lk_status_classes(:active), do: "bg-go/10 text-go border-go/40"
  def lk_status_classes(:locked), do: "bg-ink-900 text-fog-500 border-line-strong"
end
