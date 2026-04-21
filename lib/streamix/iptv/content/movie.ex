defmodule Streamix.Iptv.Movie do
  @moduledoc """
  Schema for VOD movies.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{
    CatalogItem,
    Genre,
    MovieAsset,
    MovieCredit,
    Provider,
    XtreamClient
  }

  @type t :: %__MODULE__{}

  schema "movies" do
    # Virtual scoring column populated by
    # `Streamix.Iptv.RankedSearch.apply/3`. `nil` in non-search queries;
    # otherwise an integer where higher = more relevant.
    field :rank_score, :integer, virtual: true

    field :stream_id, :integer
    field :name, :string
    field :title, :string
    field :year, :integer
    field :stream_icon, :string
    field :rating, :decimal
    field :plot, :string
    field :container_extension, :string
    field :duration_secs, :integer
    field :tmdb_id, :string
    field :imdb_id, :string
    field :youtube_trailer, :string
    field :tagline, :string
    field :content_rating, :string

    # GIndex-specific fields
    field :gindex_path, :string
    field :gindex_url_cached, :string
    field :gindex_url_expires_at, :utc_datetime

    # TMDB enrichment bookkeeping (populated by the gindex backfill worker)
    field :tmdb_searched_at, :utc_datetime
    field :tmdb_miss_reason, :string

    belongs_to :provider, Provider
    belongs_to :catalog_item, CatalogItem
    has_many :categories, through: [:catalog_item, :categories]
    many_to_many :genres, Genre, join_through: "movie_genres"
    has_many :credits, MovieCredit
    has_many :assets, MovieAsset

    timestamps(type: :utc_datetime)
  end

  @fields ~w(stream_id name title year stream_icon rating
             plot container_extension duration_secs tmdb_id imdb_id
             youtube_trailer tagline content_rating provider_id catalog_item_id
             gindex_path gindex_url_cached gindex_url_expires_at
             tmdb_searched_at tmdb_miss_reason)a

  def changeset(movie, attrs) do
    movie
    |> cast(attrs, @fields)
    |> validate_required([:stream_id, :name, :provider_id])
    |> unique_constraint([:provider_id, :stream_id])
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Returns backdrop URLs from assets, sorted by position.
  """
  @spec backdrop_urls(t()) :: [String.t()]
  def backdrop_urls(%__MODULE__{assets: assets}) when is_list(assets) do
    assets
    |> Enum.filter(&(&1.asset_type == "backdrop"))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.url)
  end

  def backdrop_urls(_), do: []

  @doc """
  Returns image URLs from assets, sorted by position.
  """
  @spec image_urls(t()) :: [String.t()]
  def image_urls(%__MODULE__{assets: assets}) when is_list(assets) do
    assets
    |> Enum.filter(&(&1.asset_type == "image"))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.url)
  end

  def image_urls(_), do: []

  @doc """
  Returns true if the movie has any backdrop assets.
  """
  @spec has_backdrops?(t()) :: boolean()
  def has_backdrops?(%__MODULE__{assets: assets}) when is_list(assets) do
    Enum.any?(assets, &(&1.asset_type == "backdrop"))
  end

  def has_backdrops?(_), do: false

  @doc """
  Returns true if the movie has any image assets.
  """
  @spec has_images?(t()) :: boolean()
  def has_images?(%__MODULE__{assets: assets}) when is_list(assets) do
    Enum.any?(assets, &(&1.asset_type == "image"))
  end

  def has_images?(_), do: false

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
