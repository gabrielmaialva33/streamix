defmodule Streamix.Programming.Station do
  @moduledoc """
  A 24h channel: a discovery `query` turned into a looping `program` of
  movies that started at `program_started_at`.

  Each program item is a map with string keys: `"movie_id"`, `"duration"`
  (seconds), `"title"`, `"year"` and `"poster"`, so listing what plays needs
  no catalog lookup.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "stations" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :query, :string
    field :position, :integer, default: 0
    field :active, :boolean, default: true
    field :program, {:array, :map}, default: []
    field :program_started_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(station, attrs) do
    station
    |> cast(attrs, [:slug, :name, :description, :query, :position, :active])
    |> validate_required([:slug, :name, :query])
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/)
    |> validate_length(:name, max: 60)
    |> unique_constraint(:slug)
  end

  @doc false
  def program_changeset(station, program, started_at) do
    change(station, program: program, program_started_at: DateTime.truncate(started_at, :second))
  end
end
