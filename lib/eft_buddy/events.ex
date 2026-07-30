defmodule EftBuddy.Events do
  @moduledoc """
  Read-only context for in-game event data scraped from the EFT Fandom
  "Events" page.

  Source of truth is the `events` + `event_quests` tables, populated
  periodically by `EftBuddy.Events.Sync`. Images are NOT stored locally —
  banners and quest screenshots carry Fandom CDN urls the browser
  fetches directly.

  Events mirror `EftBuddy.Wiki` / `EftBuddy.Chapters`: editorial wiki
  data keyed on a `normalized_name` slug that survives a
  `mix ecto.reset` / re-sync. An event's quests carry the same scraped
  manifest a `wiki_quests` row does, so `EftBuddy.Wiki.Projection`
  renders their objectives/guide identically to the Tasks tab.

  Public API:

    * `list_events/0`            — every event, newest-first, with a
      lightweight quest summary (no heavy per-quest manifest loaded).
    * `get_quest_detail/1`       — the projected walkthrough for one
      event quest, loaded on demand when a row is expanded.
    * `blacklisted_quest_slugs/0`— the set of event-quest slugs
      `EftBuddy.Wiki.Sync` excludes from `Category:Quests`, so event
      quests stop surfacing as WIP on the Tasks tab. THIS is the source
      of truth that replaces the "event quest list" — it's a single
      indexed query, no committed file.
  """

  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Wiki.Projection

  # The single wiki page every event's prose is scraped from. Keep in step with
  # `@events_page` in `EftBuddy.Events.Sync` — that attribute names the same page
  # for the API request, this is the human-readable URL for the credit line.
  @source_url "https://escapefromtarkov.fandom.com/wiki/Events"

  @doc """
  The wiki page the Events tab's content comes from.

  This is deliberately NOT an event's own `wiki_link`. Descriptions,
  availability notes and gameplay changes are all parsed out of this one shared
  page — `Events.Sync` fetches it once and splits it per event — so it is the
  page a reader should be sent to in order to check what we republished. An
  individual event's `wiki_link` points at a page about the event, which is a
  different thing and in some cases does not carry the prose at all.

  Event *quests* are the exception and keep their own credit: each is scraped
  from its own page. See `quest_detail/1` in `EftBuddyWeb.EventsLive.Index`.
  """
  @spec source_url() :: String.t()
  def source_url, do: @source_url

  @typedoc "A render-ready event with its lightweight quest summaries."
  @type event :: %{
          id: String.t(),
          slug: String.t(),
          name: String.t(),
          event_date: String.t() | nil,
          started_on: Date.t() | nil,
          status: String.t(),
          banner_url: String.t() | nil,
          description: String.t() | nil,
          wiki_link: String.t() | nil,
          availability_note: String.t() | nil,
          gameplay_changes: [%{level: integer(), text: String.t()}],
          quests: [
            %{id: String.t(), slug: String.t(), name: String.t(), task_id: String.t() | nil}
          ]
        }

  @doc """
  Every event, newest-first (`started_on` desc, then page `position`),
  each as a render-ready map with its quests summarised to just the
  fields the index needs. The heavy per-quest manifest (`content`) is
  NOT read here — it's loaded lazily by `get_quest_detail/1` when a quest
  is expanded — so the page stays cheap regardless of how many quests an
  event introduced.
  """
  @spec list_events() :: [event()]
  def list_events do
    events =
      Repo.all(from(e in Event, order_by: [desc_nulls_last: e.started_on, asc: e.position]))

    quests_by_event =
      Repo.all(
        from(q in EventQuest,
          order_by: [asc: q.position],
          select: %{
            id: q.id,
            event_id: q.event_id,
            slug: q.normalized_name,
            name: q.name,
            task_id: q.task_id
          }
        )
      )
      |> Enum.group_by(& &1.event_id)

    Enum.map(events, fn event ->
      quests =
        quests_by_event
        |> Map.get(event.id, [])
        |> Enum.map(&Map.delete(&1, :event_id))

      project_event(event, quests)
    end)
  end

  @doc """
  The projected wiki walkthrough for one event quest (by row id), or nil
  when the quest has no scraped manifest (its page failed to fetch, or
  hasn't been scraped yet). Shape matches `EftBuddy.Wiki.Projection`
  output, so the Events tab renders objectives/guide exactly like Tasks.
  """
  @spec get_quest_detail(String.t()) :: map() | nil
  def get_quest_detail(quest_id) when is_binary(quest_id) do
    case Repo.get(EventQuest, quest_id) do
      %EventQuest{content: content} when is_map(content) and map_size(content) > 0 ->
        # Merge in the full walkthrough (galleries from every walkthrough
        # section, not just one named "Guide") on top of the standard
        # projection, so quests that split their guide across per-map
        # sections still show their screenshots on the Events tab.
        content
        |> Projection.project()
        |> Map.put(:walkthrough, Projection.walkthrough(content))

      _ ->
        nil
    end
  end

  def get_quest_detail(_), do: nil

  @doc """
  The de-duplicated set of every event-quest slug, as a `MapSet`.

  `EftBuddy.Wiki.Sync` reads this to blacklist event quests from its
  `Category:Quests` scrape so they no longer write `wiki_quests` rows
  (and therefore stop appearing in the Tasks tab's WIP list). A single
  indexed `SELECT DISTINCT` — cheaper and more robust than a committed
  list file: if this sync fails, the last-known rows (and thus the
  blacklist) are preserved.
  """
  @spec blacklisted_quest_slugs() :: MapSet.t(String.t())
  def blacklisted_quest_slugs do
    Repo.all(from(q in EventQuest, select: q.normalized_name, distinct: true))
    |> MapSet.new()
  end

  # ── Private ────────────────────────────────────────────

  defp project_event(%Event{} = event, quests) do
    %{
      id: event.id,
      slug: event.normalized_name,
      name: event.name,
      event_date: event.event_date,
      started_on: event.started_on,
      status: event.status,
      banner_url: event.banner_url,
      description: event.description,
      # The wiki page the description / availability note / gameplay changes
      # were scraped from. Rendered as the event card's `source_credit` line
      # (see events_live/index.html.heex), which is what satisfies the wiki's
      # CC BY-NC-SA attribution condition for the event's own prose. The event
      # *quests* carry their own credit, each pointing at its own page.
      wiki_link: get_in(event.content, ["wiki_link"]),
      availability_note: get_in(event.content, ["availability_note"]),
      gameplay_changes: parse_changes(event.content),
      quests: quests
    }
  end

  defp parse_changes(content) when is_map(content) do
    (content["gameplay_changes"] || [])
    |> Enum.map(fn change ->
      %{level: change["level"] || 1, text: change["text"] || ""}
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  defp parse_changes(_), do: []
end
