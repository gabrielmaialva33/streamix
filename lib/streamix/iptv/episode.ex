defmodule Streamix.Iptv.Episode do
  @moduledoc """
  Schema for TV series episodes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Season, XtreamClient}

  schema "episodes" do
    field :episode_id, :integer
    field :episode_num, :integer
    field :title, :string
    field :name, :string
    field :plot, :string
    field :cover, :string
    field :still_path, :string
    field :duration_secs, :integer
    field :duration, :string
    field :container_extension, :string
    field :air_date, :date
    field :rating, :decimal
    field :tmdb_id, :integer
    field :tmdb_enriched, :boolean, default: false

    belongs_to :season, Season

    timestamps(type: :utc_datetime)
  end

  @fields ~w(episode_id episode_num title name plot cover still_path duration_secs
             duration container_extension air_date rating tmdb_id tmdb_enriched season_id)a

  def changeset(episode, attrs) do
    episode
    |> cast(attrs, @fields)
    |> validate_required([:episode_id, :episode_num, :season_id])
    |> unique_constraint([:season_id, :episode_num])
    |> unique_constraint([:season_id, :episode_id])
    |> foreign_key_constraint(:season_id)
  end

  @doc """
  Builds the stream URL for this episode.
  Requires the provider to be passed (can be obtained via season -> series -> provider).
  """
  def stream_url(%__MODULE__{episode_id: episode_id, container_extension: ext}, provider) do
    extension = ext || "mp4"

    XtreamClient.episode_stream_url(
      provider.url,
      provider.username,
      provider.password,
      episode_id,
      extension
    )
  end
end
