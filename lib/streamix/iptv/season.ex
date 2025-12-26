defmodule Streamix.Iptv.Season do
  @moduledoc """
  Schema for TV series seasons.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Episode, Series}

  schema "seasons" do
    field :season_number, :integer
    field :name, :string
    field :cover, :string
    field :air_date, :date
    field :overview, :string
    field :episode_count, :integer, default: 0

    belongs_to :series, Series
    has_many :episodes, Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(season, attrs) do
    season
    |> cast(attrs, [
      :season_number,
      :name,
      :cover,
      :air_date,
      :overview,
      :episode_count,
      :series_id
    ])
    |> validate_required([:season_number, :series_id])
    |> unique_constraint([:series_id, :season_number])
    |> foreign_key_constraint(:series_id)
  end
end
