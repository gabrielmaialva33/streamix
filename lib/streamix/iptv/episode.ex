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
    field :plot, :string
    field :cover, :string
    field :duration_secs, :integer
    field :duration, :string
    field :container_extension, :string

    belongs_to :season, Season

    timestamps(type: :utc_datetime)
  end

  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :episode_id,
      :episode_num,
      :title,
      :plot,
      :cover,
      :duration_secs,
      :duration,
      :container_extension,
      :season_id
    ])
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
