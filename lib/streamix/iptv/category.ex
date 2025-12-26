defmodule Streamix.Iptv.Category do
  @moduledoc """
  Schema for content categories (live, vod, series).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Category, Provider}

  @type_values ~w(live vod series)

  schema "categories" do
    field :external_id, :string
    field :name, :string
    field :type, :string

    belongs_to :provider, Provider
    belongs_to :parent, Category

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:external_id, :name, :type, :provider_id, :parent_id])
    |> validate_required([:external_id, :name, :type, :provider_id])
    |> validate_inclusion(:type, @type_values)
    |> unique_constraint([:provider_id, :external_id, :type])
    |> foreign_key_constraint(:provider_id)
    |> foreign_key_constraint(:parent_id)
  end
end
