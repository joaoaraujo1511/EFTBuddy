# `:external` tests hit the live tarkov.dev API. They're excluded by default so
# the suite stays offline and deterministic; run them deliberately with
# `mix test --include external` when checking for upstream shape drift.
ExUnit.start(exclude: [:external])
Ecto.Adapters.SQL.Sandbox.mode(EftBuddy.Repo, :manual)
