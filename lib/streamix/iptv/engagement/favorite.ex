defmodule Streamix.Iptv.Favorite do
  @moduledoc """
  Schema for user favorites. References content via catalog_item_id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.CatalogItem

  @type t :: %__MODULE__{}

  @primary_key false
  schema "favorites" do
    field :user_id, :id, primary_key: true
    belongs_to :catalog_item, CatalogItem, primary_key: true

    field :inserted_at, :utc_datetime, read_after_writes: true
  end

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:user_id, :catalog_item_id])
    |> validate_required([:user_id, :catalog_item_id])
    |> foreign_key_constraint(:user_id)
    |> assoc_constraint(:catalog_item)
    |> unique_constraint([:user_id, :catalog_item_id], name: :favorites_pkey)
  end
end
