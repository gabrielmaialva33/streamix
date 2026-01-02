defmodule Streamix.Iptv.Series do
  @moduledoc """
  Schema for TV series.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Category, Provider, Season}

  schema "series" do
    field :series_id, :integer
    field :name, :string
    field :title, :string
    field :year, :integer
    field :cover, :string
    field :rating, :decimal
    field :rating_5based, :decimal
    field :genre, :string
    field :cast, :string
    field :director, :string
    field :plot, :string
    field :backdrop_path, {:array, :string}
    field :youtube_trailer, :string
    field :tmdb_id, :string
    field :tagline, :string
    field :content_rating, :string
    field :images, {:array, :string}, default: []
    field :season_count, :integer, default: 0
    field :episode_count, :integer, default: 0

    # GIndex fields
    field :gindex_path, :string

    belongs_to :provider, Provider
    has_many :seasons, Season
    many_to_many :categories, Category, join_through: "series_categories"

    timestamps(type: :utc_datetime)
  end

  @fields ~w(series_id name title year cover rating rating_5based genre cast
             director plot backdrop_path youtube_trailer tmdb_id tagline
             content_rating images season_count episode_count provider_id gindex_path)a

  def changeset(series, attrs) do
    series
    |> cast(attrs, @fields)
    |> validate_required([:series_id, :name, :provider_id])
    |> unique_constraint([:provider_id, :series_id])
    |> foreign_key_constraint(:provider_id)
  end
end
