defmodule Streamix.Iptv.Series do
  @moduledoc """
  Schema for TV series.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{CatalogItem, Genre, Provider, Season, SeriesAsset, SeriesCredit}

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
    field :tagline, :string
    field :content_rating, :string

    # GIndex fields
    field :gindex_path, :string

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
             content_rating provider_id gindex_path catalog_item_id)a

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
  Returns true if the series has any backdrop assets.
  """
  @spec has_backdrops?(t()) :: boolean()
  def has_backdrops?(%__MODULE__{assets: assets}) when is_list(assets) do
    Enum.any?(assets, &(&1.asset_type == "backdrop"))
  end

  def has_backdrops?(_), do: false

  @doc """
  Returns true if the series has any image assets.
  """
  @spec has_images?(t()) :: boolean()
  def has_images?(%__MODULE__{assets: assets}) when is_list(assets) do
    Enum.any?(assets, &(&1.asset_type == "image"))
  end

  def has_images?(_), do: false
end
