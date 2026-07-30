defmodule EftBuddy.Repo do
  use Ecto.Repo,
    otp_app: :eft_buddy,
    adapter: Ecto.Adapters.Postgres
end
