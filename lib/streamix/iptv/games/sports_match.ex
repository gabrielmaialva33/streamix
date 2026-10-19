defmodule Streamix.Iptv.SportsMatch do
  @moduledoc "A credential-free sports fixture mapped to an existing live channel."
  use Ecto.Schema

  schema "sports_matches" do
    field :external_key, :string
    field :league, :string
    field :title, :string
    field :home_name, :string
    field :home_logo_url, :string
    field :away_name, :string
    field :away_logo_url, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :local_starts_at, :naive_datetime, virtual: true
    field :live, :boolean, virtual: true
    belongs_to :provider, Streamix.Iptv.Provider
    belongs_to :live_channel, Streamix.Iptv.LiveChannel
    timestamps(type: :utc_datetime)
  end
end
