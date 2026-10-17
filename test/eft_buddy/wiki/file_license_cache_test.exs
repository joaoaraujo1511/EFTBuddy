defmodule EftBuddy.Wiki.FileLicenseCacheTest do
  @moduledoc """
  The seven-day licence cache must outlive the scrape that fills it (audit M26).

  It used to be created by whichever caller asked first, and an ETS table dies
  with its owner. Every sync now runs in a short-lived process
  (`EftBuddy.Sync.Scheduler.run_isolated/1`), so the cache was discarded after
  every run and each scrape re-read thousands of file pages.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.Sync.Scheduler
  alias EftBuddy.Wiki.FileLicense

  @table :eft_buddy_wiki_file_licenses

  setup do
    on_exit(&FileLicense.clear_cache/0)
  end

  test "the table is created at boot, by a process that outlives any scrape" do
    owner = :ets.info(@table, :owner)

    assert is_pid(owner)
    assert Process.alive?(owner)
    refute owner == self()
  end

  test "entries written during a short-lived run survive it" do
    runner =
      Scheduler.run_isolated(fn ->
        # What `fetch/2` does on a successful batch.
        FileLicense.init_cache()
        :ets.insert(@table, {"File:Probe.png", :none, System.monotonic_time(:millisecond)})
        self()
      end)

    refute Process.alive?(runner)
    assert [{"File:Probe.png", :none, _}] = :ets.lookup(@table, "File:Probe.png")
  end
end
