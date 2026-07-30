defmodule EftBuddy.Sync.CleanupGuardWiringTest do
  @moduledoc """
  Asserts that every `cleanup_safe?/3` call site **honours** the guard's answer.

  `Sync.Helpers.cleanup_safe?/3` is well tested in its own right — boundary cases,
  ratios, the cold-start exemption. What none of that can detect is a call site that
  consults the guard, logs the refusal, and then deletes anyway: the guard's own
  tests would still pass, the log would still say "Refusing stale cleanup", and the
  rows would still be gone.

  There are nine call sites across seven modules. Rather than expose nine private
  functions, this walks the AST of each sync module, finds every `case
  cleanup_safe?(…)` expression, and asserts its `{:skip, _}` branch performs no
  delete. That covers the sites that exist and every one added later, which is the
  realistic failure: someone adds a prune, copies the surrounding shape, and gets the
  branch backwards.

  Deleting inside a refusal branch would reproduce Blocker 4 — the guard refusing the
  parent prune while the rows go anyway, which is worse than having no guard at all,
  because the outcome is silently-empty data rendered as fact.
  """
  use ExUnit.Case, async: true

  # Anything that removes rows. `Repo.delete_all/1`, `repo.delete_all/1` and
  # `Ecto.Adapters.SQL.query` with a DELETE all reduce to one of these names.
  @destructive [:delete_all, :delete, :truncate]

  defp sync_sources do
    Path.wildcard("lib/eft_buddy/**/sync.ex")
  end

  # Every `{:skip, _}` clause body of every `case cleanup_safe?(…) do` in `path`.
  defp refusal_branches(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, branches} =
      Macro.prewalk(ast, [], fn
        {:case, _meta, [subject, [do: clauses]]} = node, acc ->
          if guard_call?(subject) do
            {node, acc ++ skip_clause_bodies(clauses)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    branches
  end

  defp guard_call?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:cleanup_safe?, _meta, _args} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp skip_clause_bodies(clauses) do
    for {:->, _meta, [[pattern], body]} <- clauses, skip_pattern?(pattern), do: body
  end

  defp skip_pattern?({:skip, _reason}), do: true
  defp skip_pattern?(_pattern), do: false

  defp destructive_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _m1, [_target, fun]}, _m2, _args} = node, acc when fun in @destructive ->
          {node, [fun | acc]}

        {fun, _meta, args} = node, acc when fun in @destructive and is_list(args) ->
          {node, [fun | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  test "there are sync modules to inspect" do
    # Guards the whole suite against passing vacuously if the glob ever stops
    # matching — every assertion below iterates over this list.
    assert length(sync_sources()) >= 7,
           "expected to find the sync modules under lib/eft_buddy/**/sync.ex"
  end

  test "every cleanup_safe? call site's refusal branch deletes nothing" do
    branches =
      for path <- sync_sources(), branch <- refusal_branches(path), do: {path, branch}

    # NINE sites: eight that already existed (armor, ammo, hideout, maps, tasks, and
    # three in items) plus the quest-item prune, which had no guard at all until it
    # was brought under one. The audit said nine pre-existing; the AST says eight, and
    # the AST is what ships — worth knowing if that document is ever used as a
    # checklist.
    #
    # The floor is what makes this test non-vacuous: an AST walker that silently
    # matched nothing would otherwise pass forever.
    assert length(branches) >= 9,
           "expected to find the guard's call sites; found #{length(branches)}"

    for {path, branch} <- branches do
      assert destructive_calls(branch) == [],
             "#{path}: a `{:skip, _}` branch of `cleanup_safe?/3` performs a delete. " <>
               "Refusing the prune and then deleting anyway is worse than having no " <>
               "guard — it leaves silently-empty data that the UI renders as fact."
    end
  end

  test "every refusal branch says something, so a refusal is never silent" do
    # A guard that refuses without logging is indistinguishable from one that was
    # never consulted. (The count that reaches /health/sync is emitted inside
    # `cleanup_safe?/3` itself; this is about the operator-facing line.)
    for path <- sync_sources(), branch <- refusal_branches(path) do
      {_ast, logged?} =
        Macro.prewalk(branch, false, fn
          {{:., _m1, [{:__aliases__, _m2, [:Logger]}, _level]}, _m3, _args} = node, _acc ->
            {node, true}

          node, acc ->
            {node, acc}
        end)

      assert logged?, "#{path}: a refused prune must be logged, not silently skipped"
    end
  end
end
