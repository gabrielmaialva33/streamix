defmodule Streamix.Iptv.MovieCredit do
  @moduledoc """
  Join table for movie credits (cast, director, etc).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Movie, Person}

  @roles ~w(cast director writer producer)

  schema "movie_credits" do
    field :role, :string
    field :position, :integer, default: 0

    belongs_to :movie, Movie
    belongs_to :person, Person
  end

  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [:movie_id, :person_id, :role, :position])
    |> validate_required([:movie_id, :person_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:movie_id, :person_id, :role])
    |> assoc_constraint(:movie)
    |> assoc_constraint(:person)
  end
end
