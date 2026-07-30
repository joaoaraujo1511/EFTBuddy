defmodule EftBuddy.ProgressTest do
  @moduledoc """
  `EftBuddy.Progress` is the single entry point for a blob that arrives from an
  unauthenticated browser and is then held in a server process, so its bounds are
  a security boundary rather than a formatting nicety. These tests pin them.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Progress

  describe "normalize/1 is total" do
    test "coerces anything into the canonical two-mode shape" do
      for junk <- [nil, 42, "nope", [], %{}, %{"modes" => "not a map"}] do
        assert Progress.normalize(junk) == Progress.empty()
      end
    end

    test "a non-map mode slice degrades to an empty slice rather than raising" do
      blob = %{"modes" => %{"pvp" => ["not", "a", "map"], "pve" => 7}}
      assert Progress.normalize(blob) == Progress.empty()
    end
  end

  describe "normalize/1 bounds an untrusted slice" do
    test "keeps every legitimate key" do
      slice = Map.new(Progress.slice_keys(), &{&1, ["x"]})
      assert Progress.slice(%{"modes" => %{"pvp" => slice}}, :pvp) == slice
    end

    test "drops keys that are not in the allow-list" do
      slice = %{"completed_tasks" => ["debut"], "evil" => "payload", "__struct__" => "nope"}

      assert Progress.slice(%{"modes" => %{"pvp" => slice}}, :pvp) ==
               %{"completed_tasks" => ["debut"]}
    end

    test "a slice padded with thousands of junk keys collapses to the allow-listed ones" do
      junk = Map.new(1..10_000, &{"junk-#{&1}", "x"})
      slice = Map.put(junk, "tasks_watchlist", ["debut"])

      assert Progress.slice(%{"modes" => %{"pvp" => slice}}, :pvp) ==
               %{"tasks_watchlist" => ["debut"]}
    end

    test "an oversized slice under a legitimate key degrades to empty" do
      # ~2 MB of slugs under a real key: allow-listing alone would let this through.
      huge = for n <- 1..40_000, do: "task-slug-number-#{n}"
      slice = %{"completed_tasks" => huge}

      assert Progress.slice(%{"modes" => %{"pvp" => slice}}, :pvp) == %{}
    end

    test "a realistically large slice is NOT dropped" do
      # A completionist: every quest done, plus full watchlists. Must survive.
      completed = for n <- 1..1_500, do: "some-quest-slug-#{n}"
      slice = %{"completed_tasks" => completed, "tasks_watchlist" => ["debut", "shortage"]}

      assert Progress.slice(%{"modes" => %{"pvp" => slice}}, :pvp) == slice
    end

    test "one oversized mode does not take the other down with it" do
      huge = for n <- 1..40_000, do: "task-slug-number-#{n}"

      blob = %{
        "modes" => %{
          "pvp" => %{"completed_tasks" => huge},
          "pve" => %{"completed_tasks" => ["debut"]}
        }
      }

      assert Progress.slice(blob, :pvp) == %{}
      assert Progress.slice(blob, :pve) == %{"completed_tasks" => ["debut"]}
    end
  end

  # These assert on the RAW structure, never through `slice/2`.
  #
  # That distinction is the whole point of this block. `slice/2` runs `normalize/1`
  # on the way out, so it re-applies the allow-list and the ceiling to whatever it
  # is handed - which means asserting through it CANNOT detect an unsanitised
  # stored value. An earlier version of the allow-list test did exactly that and
  # passed while `merge/3` was storing the junk key verbatim.
  #
  # What is actually being pinned is that the bound is a post-condition of every
  # mutation, because the value these functions RETURN is the value
  # `EftBuddy.OperatorSession` holds for up to four hours across up to 50,000
  # sessions. An input filter on the read path does not bound that at all.
  describe "merge/3 and adopt/2 sanitise their OUTPUT" do
    defp raw(blob, mode), do: blob["modes"][Progress.mode_key(mode)]

    # A slice comfortably over the 128 KB ceiling, under a legitimate key.
    defp oversized_slice do
      %{"completed_tasks" => for(n <- 1..40_000, do: "task-slug-number-#{n}")}
    end

    test "merge writes only the named mode's slice" do
      blob = Progress.merge(Progress.empty(), :pvp, %{"completed_tasks" => ["a"]})

      assert raw(blob, :pvp) == %{"completed_tasks" => ["a"]}
      assert raw(blob, :pve) == %{}
    end

    test "merge cannot smuggle in a key outside the allow-list" do
      blob = Progress.merge(Progress.empty(), :pvp, %{"evil" => "payload"})

      assert raw(blob, :pvp) == %{},
             "the junk key must not reach the stored value, not merely be filtered on read"
    end

    test "merge keeps the allow-listed keys of a mixed patch" do
      blob =
        Progress.merge(Progress.empty(), :pvp, %{
          "completed_tasks" => ["debut"],
          "evil" => "payload"
        })

      assert raw(blob, :pvp) == %{"completed_tasks" => ["debut"]}
    end

    test "merge REJECTS an over-ceiling patch and keeps the prior slice" do
      # Rejecting the write, not discarding the history: degrading to `%{}` here
      # would let one abusive patch erase everything the operator had.
      before = Progress.merge(Progress.empty(), :pvp, %{"tasks_watchlist" => ["debut"]})
      after_write = Progress.merge(before, :pvp, oversized_slice())

      assert raw(after_write, :pvp) == %{"tasks_watchlist" => ["debut"]}
    end

    test "merge cannot be used to grow a slice past the ceiling one patch at a time" do
      # The retention bound has to hold across repeated in-spec writes, which is how
      # the unbounded version accumulated tens of MB in a single session.
      blob =
        Enum.reduce(1..40, Progress.empty(), fn n, acc ->
          chunk = for i <- 1..2_000, do: "round-#{n}-slug-#{i}"
          Progress.merge(acc, :pvp, %{"completed_tasks" => chunk, "items_watchlist" => chunk})
        end)

      assert :erlang.external_size(raw(blob, :pvp)) <= Progress.max_slice_bytes()
    end

    test "adopt/2 lets the SECOND argument win key-by-key" do
      client = %{"modes" => %{"pvp" => %{"completed_tasks" => ["client"], "hideout" => %{}}}}
      server = %{"modes" => %{"pvp" => %{"completed_tasks" => ["server"]}}}

      # Server wins where both know a key; the client's extra key is carried up.
      # This is what stops a resurrected session erasing the browser's copy.
      assert raw(Progress.adopt(client, server), :pvp) ==
               %{"completed_tasks" => ["server"], "hideout" => %{}}
    end

    test "adopt/2 bounds a union of two individually-legal slices" do
      # Each side is inside the ceiling; together they are not. Without bounding the
      # output the result would be ~2x the cap - and a slice over the cap reads back
      # as `%{}`, i.e. progress present in storage but invisible everywhere.
      half = fn tag -> for n <- 1..3_000, do: "#{tag}-quest-slug-number-#{n}" end

      client = %{"modes" => %{"pvp" => %{"completed_tasks" => half.("c")}}}
      server = %{"modes" => %{"pvp" => %{"items_watchlist" => half.("s")}}}

      # Guard against the test passing vacuously: BOTH sides must survive
      # normalisation on their own, or there would be no union to bound.
      refute raw(Progress.normalize(client), :pvp) == %{}
      refute raw(Progress.normalize(server), :pvp) == %{}

      # ...and their union must genuinely exceed the ceiling, or nothing is tested.
      naive_union =
        Map.merge(raw(Progress.normalize(client), :pvp), raw(Progress.normalize(server), :pvp))

      assert :erlang.external_size(naive_union) > Progress.max_slice_bytes()

      assert :erlang.external_size(raw(Progress.adopt(client, server), :pvp)) <=
               Progress.max_slice_bytes()
    end

    test "mode_key/1 falls back to pvp for anything unrecognised" do
      assert Progress.mode_key(:pve) == "pve"
      assert Progress.mode_key("pvp") == "pvp"
      assert Progress.mode_key("wat") == "pvp"
      assert Progress.mode_key(nil) == "pvp"
    end
  end
end
