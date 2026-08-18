defmodule EftBuddy.Sync.BootstrapTest do
  @moduledoc """
  When each feed is released, which is a different question from whether it runs.

  A feed is released by `:bootstrap_complete`, which tells it to anchor its
  recurring timer. Until that arrives it holds a short fallback timer meaning
  "Bootstrap died, run yourself". So the release has to land before that fallback
  expires — and the sequence got slower than the shortest fallback the moment the
  Fandom scrapes joined it.

  `EftBuddy.Chapters.Sync` hit exactly that on the first deploy: released at the
  end of a sequence that ran for sixteen minutes, with a fifteen-minute fallback,
  it re-scraped the eleven pages it had written fourteen minutes earlier. The
  registry's shape cannot express this; only the ordering can, which is why these
  drive `run_cold_start_steps/1` with synthetic steps.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.Sync.Bootstrap

  # Stands in for a feed. Registers globally under its own module name, because
  # that is how `notify_step/3` addresses a recipient.
  defmodule StubFeed do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, [], name: {:global, name})

    @impl true
    def init(_), do: {:ok, %{casts: []}}

    @impl true
    def handle_cast(msg, state), do: {:noreply, %{state | casts: [msg | state.casts]}}

    @impl true
    def handle_call(:casts, _from, state), do: {:reply, Enum.reverse(state.casts), state}
  end

  defmodule FeedA do
  end

  defmodule FeedB do
  end

  setup do
    {:ok, a} = StubFeed.start_link(FeedA)
    {:ok, b} = StubFeed.start_link(FeedB)

    on_exit(fn ->
      for pid <- [a, b], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  defp casts(name), do: GenServer.call({:global, name}, :casts)

  describe "releasing a feed" do
    test "happens while later steps are still running, not after all of them" do
      # THE REGRESSION. With the release deferred to the end of the sequence, a
      # feed whose own step finished early spends the remainder of the sequence
      # holding a live fallback timer and no lock — and a long enough sequence
      # means that fallback fires and re-runs work that just completed.
      test_pid = self()

      steps = [
        %{label: "a", run: fn -> {:ok, :done} end, notify: FeedA},
        %{
          label: "slow-one-after",
          run: fn ->
            send(test_pid, {:during_later_step, casts(FeedA)})
            {:ok, :done}
          end
        }
      ]

      Bootstrap.run_cold_start_steps(steps)

      assert_receive {:during_later_step, [:bootstrap_complete]},
                     1_000,
                     "FeedA must be released by the time a later step runs, not at the end"
    end

    test "a failed step leaves its feed on the short fallback" do
      # Releasing a feed whose step failed would anchor it a FULL interval out,
      # with nothing written — an empty table until tomorrow. The fallback is
      # measured in minutes and is exactly the right timer for that state.
      steps = [%{label: "a", run: fn -> {:error, :upstream_gone} end, notify: FeedA}]

      Bootstrap.run_cold_start_steps(steps)

      assert casts(FeedA) == []
    end

    test "a skipped step also leaves its feed on the fallback" do
      # A skip means the feed ran and wrote nothing, which is likewise better
      # served by retrying in minutes than by a full cycle.
      steps = [%{label: "a", run: fn -> {:skip, :nothing_to_do} end, notify: FeedA}]

      Bootstrap.run_cold_start_steps(steps)

      assert casts(FeedA) == []
    end

    test "a crashing step leaves its feed on the fallback rather than taking the sequence down" do
      steps = [
        %{label: "boom", run: fn -> raise "upstream exploded" end, notify: FeedA},
        %{label: "b", run: fn -> {:ok, :done} end, notify: FeedB}
      ]

      Bootstrap.run_cold_start_steps(steps)

      assert casts(FeedA) == []
      # The sequence continues — a partial cold start beats none.
      assert casts(FeedB) == [:bootstrap_complete]
    end

    test "a step skipped for a failed dependency does not release its feed" do
      steps = [
        %{label: "root", key: :root, run: fn -> {:error, :nope} end},
        %{label: "dependent", requires: :root, run: fn -> {:ok, :done} end, notify: FeedA}
      ]

      Bootstrap.run_cold_start_steps(steps)

      assert casts(FeedA) == []
    end

    test "a step with no :notify releases nobody and is not an error" do
      steps = [%{label: "anonymous", run: fn -> {:ok, :done} end}]

      assert Bootstrap.run_cold_start_steps(steps) == []
    end

    test "returns the feeds it released, so the caller can name the ones it did not" do
      steps = [
        %{label: "a", run: fn -> {:ok, :done} end, notify: FeedA},
        %{label: "b", run: fn -> {:error, :nope} end, notify: FeedB}
      ]

      assert Bootstrap.run_cold_start_steps(steps) == [FeedA]
    end

    test "a feed is released exactly once, even across several of its own steps" do
      # `EftBuddy.Items.Sync` contributes two steps and carries `:notify` on the
      # later one. Were it on both, the second cast would cancel and re-arm a
      # timer the first had just set — harmless but incoherent, and it would mask
      # the ordering bug this whole change is about.
      steps = [
        %{label: "a1", run: fn -> {:ok, :done} end},
        %{label: "a2", run: fn -> {:ok, :done} end, notify: FeedA}
      ]

      Bootstrap.run_cold_start_steps(steps)

      assert casts(FeedA) == [:bootstrap_complete]
    end
  end
end
