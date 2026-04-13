defmodule Streamix.Iptv.Genre do
  @moduledoc """
  Schema for content genres.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "genres" do
    field :name, :string

    many_to_many :movies, Streamix.Iptv.Movie, join_through: "movie_genres"
    many_to_many :series, Streamix.Iptv.Series, join_through: "series_genres"

    timestamps(type: :utc_datetime)
  end

  def changeset(genre, attrs) do
    genre
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
