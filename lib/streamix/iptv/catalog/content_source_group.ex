defmodule Streamix.Iptv.ContentSourceGroup do
  @moduledoc """
  Canonical identity shared by equivalent catalog sources.

  A group does not own playback URLs. It only links provider-scoped
  `CatalogItem` rows that represent the same work, keeping source selection
  reversible and auditable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Streamix.Iptv.CatalogItem

  @content_types ~w(live_channel movie series episode)

  @type t :: %__MODULE__{}

  schema "content_source_groups" do
    field :content_type, :string
    field :canonical_key, :string
    field :canonical_title, :string
    field :canonical_year, :integer

    has_many :catalog_items, CatalogItem, foreign_key: :source_group_id

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:content_type, :canonical_key, :canonical_title, :canonical_year])
    |> validate_required([:content_type, :canonical_key])
    |> validate_inclusion(:content_type, @content_types)
    |> validate_length(:canonical_key, max: 255)
    |> unique_constraint([:content_type, :canonical_key])
  end
end
