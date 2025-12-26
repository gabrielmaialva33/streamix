defmodule Streamix.Iptv.Movie do
  @moduledoc """
  Schema for VOD movies.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Category, Provider, XtreamClient}

  schema "movies" do
    field :stream_id, :integer
    field :name, :string
    field :title, :string
    field :year, :integer
    field :stream_icon, :string
    field :rating, :decimal
    field :rating_5based, :decimal
    field :genre, :string
    field :cast, :string
    field :director, :string
    field :plot, :string
    field :container_extension, :string
    field :duration_secs, :integer
    field :duration, :string
    field :tmdb_id, :string
    field :imdb_id, :string
    field :backdrop_path, {:array, :string}
    field :youtube_trailer, :string

    belongs_to :provider, Provider
    many_to_many :categories, Category, join_through: "movie_categories"

    timestamps(type: :utc_datetime)
  end

  @fields ~w(stream_id name title year stream_icon rating rating_5based genre cast
             director plot container_extension duration_secs duration tmdb_id imdb_id
             backdrop_path youtube_trailer provider_id)a

  def changeset(movie, attrs) do
    movie
    |> cast(attrs, @fields)
    |> validate_required([:stream_id, :name, :provider_id])
    |> unique_constraint([:provider_id, :stream_id])
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Builds the stream URL for this movie.
  """
  def stream_url(
        %__MODULE__{stream_id: stream_id, container_extension: ext},
        %Provider{} = provider
      ) do
    extension = ext || "mp4"

    XtreamClient.movie_stream_url(
      provider.url,
      provider.username,
      provider.password,
      stream_id,
      extension
    )
  end
end
