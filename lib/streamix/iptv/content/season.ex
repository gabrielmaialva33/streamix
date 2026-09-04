defmodule Streamix.Iptv.Season do
  @moduledoc """
  Schema for TV series seasons.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Episode, Series}

  @type t :: %__MODULE__{}

  schema "seasons" do
    field :season_number, :integer
    field :name, :string
    field :cover, :string
    field :air_date, :date
    field :overview, :string
    field :episode_count, :integer, default: 0

    # Stamped by `Streamix.Workers.EpisodeDetailsWorker` once TMDB's season
    # payload has been read. Written programmatically, so it stays out of
    # `changeset/2` — and out of the sync's replace list, which is what keeps a
    # sync from resetting it.
    field :tmdb_details_at, :utc_datetime

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
