defmodule Streamix.Iptv.SeriesAsset do
  @moduledoc """
  Schema for series media assets (poster, backdrop, image, cover).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Series

  @asset_types ~w(poster backdrop image cover)

  @type t :: %__MODULE__{}

  schema "series_assets" do
    field :asset_type, :string
    field :url, :string
    field :position, :integer, default: 0

    belongs_to :series, Series

    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:series_id, :asset_type, :url, :position])
    |> validate_required([:series_id, :asset_type, :url])
    |> validate_inclusion(:asset_type, @asset_types)
    |> assoc_constraint(:series)
  end
end
