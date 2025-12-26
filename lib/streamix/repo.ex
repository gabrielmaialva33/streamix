defmodule Streamix.Repo do
  use Ecto.Repo,
    otp_app: :streamix,
    adapter: Ecto.Adapters.Postgres
end
