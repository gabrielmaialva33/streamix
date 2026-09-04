defmodule Streamix.Iptv.Series do
  @moduledoc """
  Schema for TV series.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Assets, CatalogItem, Genre, Provider, Season, SeriesAsset, SeriesCredit}

  @type t :: %__MODULE__{}

  schema "series" do
    # Virtual scoring column populated by
    # `Streamix.Iptv.RankedSearch.apply/3`. `nil` in non-search queries;
    # otherwise an integer where higher = more relevant.
    field :rank_score, :integer, virtual: true

    field :series_id, :integer
    field :name, :string
    field :title, :string
    field :year, :integer
    field :cover, :string
    field :rating, :decimal
    field :plot, :string
    field :youtube_trailer, :string
    field :tmdb_id, :string
    field :variant_key, :string, writable: :never, load_in_query: false
    field :tagline, :string
    field :content_rating, :string

    # GIndex fields
    field :gindex_path, :string

    # TMDB enrichment bookkeeping (populated by the gindex backfill worker)
    field :tmdb_searched_at, :utc_datetime
    field :tmdb_miss_reason, :string

    # Stamped by `Streamix.Workers.TmdbDetailsWorker` once the TMDB *details*
    # endpoint has been read for this row. Distinct from `tmdb_searched_at`,
    # which only records that we looked for a match. Written programmatically,
    # so it is deliberately absent from `@fields`.
    field :tmdb_details_at, :utc_datetime

    # AniList fallback for anime rows that TMDB couldn't match.
    field :anilist_id, :integer

    # TomatoAnimes: primary enrichment source for rows under `/Animes/`.
    field :tomato_id, :integer
    field :dub_available, :boolean, default: false

    belongs_to :provider, Provider
    belongs_to :catalog_item, CatalogItem
    has_many :seasons, Season
    has_many :categories, through: [:catalog_item, :categories]
    many_to_many :genres, Genre, join_through: "series_genres"
    has_many :credits, SeriesCredit
    has_many :assets, SeriesAsset

    timestamps(type: :utc_datetime)
  end

  @fields ~w(series_id name title year cover rating
             plot youtube_trailer tmdb_id tagline
             content_rating provider_id gindex_path catalog_item_id
             tmdb_searched_at tmdb_miss_reason anilist_id
             tomato_id dub_available)a

  def changeset(series, attrs) do
    series
    |> cast(attrs, @fields)
    |> validate_required([:series_id, :name, :provider_id])
    |> unique_constraint([:provider_id, :series_id])
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Returns backdrop URLs from assets, sorted by position.
  """
  @spec backdrop_urls(t()) :: [String.t()]
  defdelegate backdrop_urls(series), to: Assets

  @doc """
  Returns image URLs from assets, sorted by position.
  """
  @spec image_urls(t()) :: [String.t()]
  defdelegate image_urls(series), to: Assets

  @doc """
  Returns true if the series has any backdrop assets.
  """
  @spec has_backdrops?(t()) :: boolean()
  defdelegate has_backdrops?(series), to: Assets

  @doc """
  Returns true if the series has any image assets.
  """
  @spec has_images?(t()) :: boolean()
  defdelegate has_images?(series), to: Assets
end
