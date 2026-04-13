defmodule Streamix.Iptv.Person do
  @moduledoc """
  Schema for people (actors, directors, etc).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "people" do
    field :name, :string

    has_many :movie_credits, Streamix.Iptv.MovieCredit
    has_many :series_credits, Streamix.Iptv.SeriesCredit

    timestamps(type: :utc_datetime)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
