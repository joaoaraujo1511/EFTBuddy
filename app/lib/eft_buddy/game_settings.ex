defmodule EftBuddy.GameSettings do
  @moduledoc """
  Tiny key/value store for global game constants pulled from the
  tarkov.dev API that don't belong to a single item/task/map row.

  Currently the only key is `"flea_market_min_player_level"` — the PMC
  level at which the flea market unlocks (`fleaMarket.minPlayerLevel`,
  15 today), written by `EftBuddy.Items.Sync` on the full pipeline and
  read by the flea-market lock as its hard floor.

  Reads are intentionally a single cheap indexed lookup with a caller-
  supplied default, so callers stay correct even before the first sync
  populates the row (cold start) or if the API ever drops the field.
  """

  import Ecto.Query

  alias EftBuddy.GameSettings.Setting
  alias EftBuddy.Repo

  @doc """
  Fetch an integer setting by `key`, returning `default` when the key is
  absent or its `int_value` is NULL.
  """
  def get_int(key, default) when is_binary(key) and is_integer(default) do
    case Repo.one(from s in Setting, where: s.key == ^key, select: s.int_value) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Upsert an integer setting. Idempotent — conflicts on `key` replace the
  value and `updated_at`. Used by the sync; a `nil` value is ignored so a
  transient missing API field never clobbers a known-good setting.

  When the stored value already equals `value` the write is skipped
  entirely (returning `{:ok, :unchanged}`), so the periodic sync doesn't
  churn an identical row — and emit a noisy `INSERT … ON CONFLICT` log —
  on every run for a constant like the flea unlock level.
  """
  def put_int(_key, nil), do: {:ok, :ignored}

  def put_int(key, value) when is_binary(key) and is_integer(value) do
    case Repo.one(from s in Setting, where: s.key == ^key, select: s.int_value) do
      ^value ->
        {:ok, :unchanged}

      _ ->
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        {1, _} =
          Repo.insert_all(
            Setting,
            [
              %{
                id: Ecto.UUID.generate(),
                key: key,
                int_value: value,
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: {:replace, [:int_value, :updated_at]},
            conflict_target: :key
          )

        {:ok, value}
    end
  end

  # A non-integer / unexpected value (e.g. the API field went missing or
  # changed shape) is ignored rather than crashing the sync — the prior
  # known-good setting (or the caller's default) stands.
  def put_int(_key, _value), do: {:ok, :ignored}
end
