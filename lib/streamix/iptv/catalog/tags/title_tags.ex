defmodule Streamix.Iptv.TitleTags do
  @moduledoc """
  The classified tags of one title (`kind` + `variant_key`), shared by every
  provider copy of it. Slugs are validated against
  `Streamix.Iptv.Tags.Vocabulary`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Tags.Vocabulary

  @kinds ~w(movies series)
  @list_facets [:subgenres, :moods, :eras, :settings, :themes, :origins]

  schema "title_tags" do
    field :kind, :string
    field :variant_key, :string
    field :subgenres, {:array, :string}, default: []
    field :moods, {:array, :string}, default: []
    field :pace, :string
    field :eras, {:array, :string}, default: []
    field :settings, {:array, :string}, default: []
    field :audience, :string
    field :themes, {:array, :string}, default: []
    field :origins, {:array, :string}, default: []
    field :vocabulary_version, :integer
    field :model, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(tags, attrs) do
    tags
    |> cast(attrs, [
      :kind,
      :variant_key,
      :pace,
      :audience,
      :model,
      :vocabulary_version | @list_facets
    ])
    |> validate_required([:kind, :variant_key, :model, :vocabulary_version])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:pace, Vocabulary.slugs(:pace))
    |> validate_inclusion(:audience, Vocabulary.slugs(:audience))
    |> validate_facets()
    |> unique_constraint([:kind, :variant_key])
  end

  defp validate_facets(changeset) do
    Enum.reduce(@list_facets, changeset, fn facet, changeset ->
      changeset
      |> validate_subset(facet, Vocabulary.slugs(facet))
      |> validate_length(facet, max: Vocabulary.limit(facet))
    end)
  end
end
