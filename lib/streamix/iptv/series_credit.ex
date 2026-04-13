defmodule Streamix.Iptv.SeriesCredit do
  @moduledoc """
  Join table for series credits (cast, director, etc).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Person, Series}

  @roles ~w(cast director writer producer)

  schema "series_credits" do
    field :role, :string
    field :position, :integer, default: 0

    belongs_to :series, Series
    belongs_to :person, Person
  end

  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [:series_id, :person_id, :role, :position])
    |> validate_required([:series_id, :person_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:series_id, :person_id, :role])
    |> assoc_constraint(:series)
    |> assoc_constraint(:person)
  end
end
