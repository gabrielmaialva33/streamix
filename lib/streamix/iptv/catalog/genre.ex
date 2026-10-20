defmodule Streamix.Iptv.Genre do
  @moduledoc """
  Schema for content genres.

  Canonical genres come from `Streamix.Iptv.Genres.Vocabulary`: `slug` is
  their stable identity and `name` the pt-BR label. Sync never creates a
  genre; it maps provider strings onto these rows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "genres" do
    field :name, :string
    field :slug, :string
    field :position, :integer

    many_to_many :movies, Streamix.Iptv.Movie, join_through: "movie_genres"
    many_to_many :series, Streamix.Iptv.Series, join_through: "series_genres"

    timestamps(type: :utc_datetime)
  end

  def changeset(genre, attrs) do
    genre
    |> cast(attrs, [:name, :slug, :position])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
