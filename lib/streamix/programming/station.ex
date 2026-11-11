defmodule Streamix.Programming.Station do
  @moduledoc """
  A 24h channel: a looping `program` that started at `program_started_at`.

  A `"movies"` station plays the movies its discovery `query` finds; a
  `"series"` station plays random episodes of the series in
  `series_tmdb_ids` (one for "Chaves 24h", several for a marathon).

  Each program item is a map with string keys: `"type"` (`"movie"` or
  `"episode"`), `"content_id"`, `"duration"` (seconds), `"title"`,
  `"subtitle"` (an episode's "T3:E7 · name"), `"year"` and `"poster"`, so
  listing what plays needs no catalog lookup. Programs built before episodes
  existed carry `"movie_id"` instead of type and id; `item_ref/1` reads both.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "stations" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :query, :string
    field :kind, :string, default: "movies"
    field :series_tmdb_ids, {:array, :string}, default: []
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
    |> cast(attrs, [
      :slug,
      :name,
      :description,
      :query,
      :kind,
      :series_tmdb_ids,
      :position,
      :active
    ])
    |> validate_required([:slug, :name, :query, :kind])
    |> validate_inclusion(:kind, ~w(movies series))
    |> validate_series()
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/)
    |> validate_length(:name, max: 60)
    |> unique_constraint(:slug)
  end

  defp validate_series(changeset) do
    if get_field(changeset, :kind) == "series" and get_field(changeset, :series_tmdb_ids) == [],
      do: add_error(changeset, :series_tmdb_ids, "lists no series"),
      else: changeset
  end

  @doc ~s(What an item plays: `{"movie" | "episode", id}`, or nil.)
  @spec item_ref(map()) :: {String.t(), integer()} | nil
  def item_ref(%{"type" => type, "content_id" => id})
      when type in ["movie", "episode"] and is_integer(id),
      do: {type, id}

  def item_ref(%{"movie_id" => id}) when is_integer(id), do: {"movie", id}
  def item_ref(_item), do: nil

  @doc false
  def program_changeset(station, program, started_at) do
    change(station, program: program, program_started_at: DateTime.truncate(started_at, :second))
  end
end
