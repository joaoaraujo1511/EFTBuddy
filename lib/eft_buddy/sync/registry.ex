defmodule EftBuddy.Sync.Registry do
  @moduledoc """
  Every background feed, in one list, with the three facts about it that more
  than one place needs: whether the supervisor starts it, whether the cold start
  runs it and in what order, and whether `:bootstrap_complete` is cast to it.

  ## Why this is one list and not three

  It was three, and they disagreed. `EftBuddy.Application` held the supervision
  children, `EftBuddy.Sync.Bootstrap.do_run/0` held the cold-start order, and
  `notify_schedulers/0` held a hardcoded list of who gets the completion cast.

  `EftBuddy.Items.Sync` was missing from the third one. Nothing failed and
  nothing logged: it simply never received the cast, so instead of anchoring its
  first run to the end of the cold start it armed a timer in `init/1` and drifted
  from boot forever. A feed left out of that list gets no error — it just runs on
  the wrong schedule, quietly, which is the same class of failure the freshness
  probe exists to catch and cannot see.

  Splitting the feeds out of `EftBuddy.Items.Sync` would have added six more
  chances to make exactly that mistake. `registry_test.exs` now asserts that
  every `lib/eft_buddy/**/sync.ex` module appears here, so the next one cannot be
  forgotten.

  ## Fields

    * `:mod` — the module. Must `use EftBuddy.Sync.Scheduler`.
    * `:bootstrap` — mirrors the module's own `bootstrap_mode/0`; feeds that are
      `:ran` or `:released` receive the completion cast.

  ## The cold start is a list of CALLS, not of feeds

  Deliberately a second list. `EftBuddy.Items.Sync` currently contributes two
  cold-start steps — `run_items/0` and, later in the order,
  `run_barters_and_crafts/0` — because it is still one module running several
  feeds' work. A single list keyed by module could not express that without
  pretending the module appears twice, which would break `children/0` and
  `notifiable/0`.

  When those feeds are extracted into modules of their own, each gets an ordinary
  entry here and the two lists line up one-to-one.

  ### Fields

    * `:label` — what the step logs as.
    * `:run` — a zero-arity function.
    * `:key` — optional tag, so a later step can depend on this one's outcome.
    * `:requires` — skip this step unless the step with that `:key` succeeded.

  ## On the ordering

  The cold-start order is the FK graph, not a preference: items are the root;
  maps precede tasks because `tasks.map_id` resolves against them; hideout and
  tasks both seed traders that barters and crafts resolve against.

  Nothing DEPENDS on the recurring cycle honouring the same order — every sync is
  idempotent and re-links its FKs next run — but the cold start does, because
  there is no previous run to have linked anything.
  """

  @feeds [
    %{mod: EftBuddy.Items.Sync, bootstrap: :ran},
    %{mod: EftBuddy.Maps.Sync, bootstrap: :ran},
    %{mod: EftBuddy.Ammo.Sync, bootstrap: :ran},
    %{mod: EftBuddy.Armor.Sync, bootstrap: :ran},
    %{mod: EftBuddy.Hideout.Sync, bootstrap: :ran},
    %{mod: EftBuddy.Tasks.Sync, bootstrap: :ran},

    # The three Fandom scrapes. None is in the cold start: Bootstrap releases the
    # first two by cast and the quest scrape chains off the events one.
    %{mod: EftBuddy.Chapters.Sync, bootstrap: :released},
    %{mod: EftBuddy.Events.Sync, bootstrap: :released},
    %{mod: EftBuddy.Wiki.Sync, bootstrap: :chained}
  ]

  @doc "Every registered feed."
  def all, do: @feeds

  @doc """
  Supervision children, in start order.

  `EftBuddy.Sync.Bootstrap` is NOT here — it must start after all of these so its
  casts land on running processes, and `EftBuddy.Application` adds it last.
  """
  def children, do: Enum.map(@feeds, & &1.mod)

  @doc """
  Feeds that should receive `:bootstrap_complete`.

  `:chained` and `:none` feeds are excluded: the first is armed by another
  module's cast, the second by nothing.
  """
  def notifiable, do: for(f <- @feeds, f.bootstrap in [:ran, :released], do: f.mod)

  @doc "The cold-start sequence, in dependency order."
  def cold_start_steps do
    [
      %{label: "Items (items + prices)", key: :items, run: &EftBuddy.Items.Sync.run_items/0},
      %{label: "Maps", run: &EftBuddy.Maps.Sync.run/0},

      # Ammo ballistics and armor plates link back to items for name / icon /
      # price. Like Maps they only drop the item-keyed link they cannot resolve —
      # leaving `item_id` null and re-linking next run — so they are not
      # `requires: :items`.
      %{label: "Ammo", run: &EftBuddy.Ammo.Sync.run/0},
      %{label: "Armor", run: &EftBuddy.Armor.Sync.run/0},
      %{label: "Hideout", run: &EftBuddy.Hideout.Sync.run/0},
      %{label: "Tasks", run: &EftBuddy.Tasks.Sync.run/0},

      # The exception. Every parent FK here resolves against the items written by
      # the first step, so with no items this would fetch the whole barter/craft
      # set from the API only to sanitise all of it away.
      %{
        label: "Items (barters & crafts)",
        requires: :items,
        run: &EftBuddy.Items.Sync.run_barters_and_crafts/0
      }
    ]
  end
end
