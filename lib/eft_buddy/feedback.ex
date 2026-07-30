defmodule EftBuddy.Feedback do
  @moduledoc """
  Context for user-submitted feedback.

  This is the in-site bug-report form: a small write path that persists
  `EftBuddy.Feedback.BugReport` rows.

  The read functions below have no caller in `lib/` on purpose. There is no
  in-app triage page — see `EftBuddy.Feedback.BugReport` for why — so reports
  are read from the database host's console, or from IEx via these. They are
  kept (rather than deleted as dead code) because they are the documented,
  bounded way to inspect the table, and an unbounded `Repo.all` typed into a
  production console is exactly what they exist to prevent.

  ## Why there is a rate limiter in here

  This is the ONLY way an anonymous visitor can write to the database, and
  `bug_reports` is the only table in the application that is not re-derivable
  from tarkov.dev or the wiki. There is no CAPTCHA, no account and no WAF in
  front of it.

  The near-term harm of a flood is not the disk — it is the connection pool.
  `POOL_SIZE` defaults to 10 and every page in the app shares it, so a handful
  of sockets looping inserts degrades the whole site long before storage
  matters. It would also drown the triage page in exactly the situation you
  would want to read it.

  Two independent controls, because either alone is insufficient:

    * a **per-socket cooldown**, held in the LiveView's assigns
      (`EftBuddyWeb.ReportBugLive.Index`), which stops one client hammering; and
    * the **global ceiling** here, which stops N clients multiplying around it.

  ## Why `:atomics` rather than a counter in `:persistent_term`

  `:persistent_term.put/2` triggers a global garbage-collection scan of every
  process holding a reference to the term. That is fine once, at boot; doing it
  per submission would mean the mitigation for a flood is itself a
  denial-of-service under exactly the load it exists to handle.

  So `:persistent_term` holds the `:atomics` reference — written once by
  `init_rate_limiter/0`, read many times — and the mutable counter lives in the
  atomics array, where updates are lock-free and allocate nothing.
  """

  import Ecto.Query, only: [from: 2]

  alias EftBuddy.Repo
  alias EftBuddy.Feedback.BugReport

  @limiter_key {__MODULE__, :rate_limiter}

  # Slot 1 holds the current window's start (unix seconds), slot 2 its count.
  @window_slot 1
  @count_slot 2

  @window_seconds 60
  @default_max_per_window 30

  # A listing page is a triage queue, not an archive: the newest reports are the
  # ones you act on. Bounding it also means a spam burst cannot make the page
  # itself unusable — which is precisely when you would go looking at it.
  @default_limit 200

  @doc """
  Allocate the global rate-limiter counter.

  Called once from `EftBuddy.Application.start/2`. Separate from the limiter
  itself so the `:persistent_term` write happens exactly once at boot rather
  than racing on first use.
  """
  @spec init_rate_limiter() :: :ok
  def init_rate_limiter do
    ref = :atomics.new(2, signed: false)
    :atomics.put(ref, @window_slot, System.system_time(:second))
    :persistent_term.put(@limiter_key, ref)
    :ok
  end

  @doc """
  Ask whether one more report may be accepted right now.

  Returns `:ok` or `{:error, :rate_limited}`. Counts the attempt either way —
  a client that keeps hammering keeps failing until the window rolls, which is
  the desired behaviour.

  Fails **open** when the limiter was never allocated (narrow test setups that
  do not start the application): losing a bug report because a counter is
  missing is worse than accepting one too many.
  """
  @spec admit(integer()) :: :ok | {:error, :rate_limited}
  def admit(now \\ System.system_time(:second)) do
    case :persistent_term.get(@limiter_key, nil) do
      nil -> :ok
      ref -> admit_against(ref, now)
    end
  end

  defp admit_against(ref, now) do
    window = :atomics.get(ref, @window_slot)

    if now - window >= @window_seconds do
      # Roll the window exactly once even if several processes notice
      # simultaneously. The winner resets the count and is admitted; a loser
      # re-reads and falls through to the counting branch below, so a rollover
      # can never hand out two free windows.
      case :atomics.compare_exchange(ref, @window_slot, window, now) do
        :ok ->
          :atomics.put(ref, @count_slot, 1)
          :ok

        _other ->
          admit_against(ref, now)
      end
    else
      if :atomics.add_get(ref, @count_slot, 1) > max_per_window() do
        {:error, :rate_limited}
      else
        :ok
      end
    end
  end

  @doc "Reports admitted per #{@window_seconds}s window before the global ceiling trips."
  @spec max_per_window() :: pos_integer()
  def max_per_window do
    Application.get_env(:eft_buddy, :max_bug_reports_per_minute, @default_max_per_window)
  end

  @doc "Length of the global rate-limit window, in seconds."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  Returns a blank changeset for the bug-report form (and re-renders on
  `phx-change` validation).
  """
  def change_bug_report(%BugReport{} = bug_report \\ %BugReport{}, attrs \\ %{}) do
    BugReport.changeset(bug_report, attrs)
  end

  @doc """
  Persist a bug report. Returns `{:ok, %BugReport{}}` or
  `{:error, %Ecto.Changeset{}}`.

  Admission control is the CALLER's job — see `admit/1`. Keeping it out of here
  means a future path that legitimately bypasses the limit (an import, a
  console) does not have to defeat it.
  """
  def create_bug_report(attrs) do
    %BugReport{}
    |> BugReport.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List bug reports, newest first, bounded by `:limit` (default #{@default_limit}).
  """
  def list_bug_reports(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Repo.all(from b in BugReport, order_by: [desc: b.inserted_at], limit: ^limit)
  end

  @doc "How many bug reports exist in total, so the listing can say what it is not showing."
  @spec count_bug_reports() :: non_neg_integer()
  def count_bug_reports, do: Repo.aggregate(BugReport, :count, :id)
end
